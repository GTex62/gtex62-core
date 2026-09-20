# MEDIA Event-Driven Refresh — Design

**Status: draft, investigation output. Nothing in this doc is implemented** except the idle
fast-path stopgap described under [Stopgap already shipped](#stopgap-already-shipped).
No build is scheduled; this doc exists so the decision is made once, on the evidence
below, instead of across chat rounds.

Written 2026-09-20. Builds on [lyrics-library-design.md](lyrics-library-design.md) (the
`media` domain itself) and [core-launcher-design.md](core-launcher-design.md) (the
launcher's process model). Would be the **first domain in core built outside the
poll-and-exit/TTL model** every other domain uses — that is the main reason this is a
design doc and not a quick fix.

---

## Summary

- MEDIA (`providers/media/fetch_lyrics.sh` → `fetch_lyrics.py`) is polled by
  `refresh_loop` every `poll_interval_sec` (default 5s), once per running suite launcher,
  forever, whether or not a player exists.
- The main cost is **not** idle — it is the steady-state cycle *while a track plays*:
  about 0.3s wall and ~0.23s CPU per cycle per loop, of which the per-cycle NAS
  `os.listdir()` is about a fifth. See [Motivation](#motivation).
- A listener that subscribes to MPRIS D-Bus signals with **daemon-side filters** is a viable
  replacement: measured 0.0 ms CPU over 30s idle, versus 34 ms for stock
  `playerctl --follow` (which is *not* free) and ~160 ms per poll cycle.
- It does not fit `refresh_loop`. Six concrete launcher-integration problems (listed under
  [Core open questions](#core-open-questions)) have to be solved first; none is
  a blocker, all are real work.

---

## Motivation

Measured 2026-09-20 on the live workstation (Linux 7.0, session bus `dbus-daemon`, two
live media loops — the `osa` and `sitrep` suites — both polling every 5s; `media = true`
in the live `core.toml`). All wall/CPU figures are per single provider invocation unless
noted.

### Primary: steady-state cost while a player is active

A poll cycle with a player running does far more than an idle one: three `playerctl`
spawns, a directory listing of the NAS library, a lookup, a file read, and two JSON
rewrites — every 5s for the whole length of every track, even when nothing has changed
since the last cycle.

| Measurement (playing, local-library hit, real NAS) | Result |
| --- | --- |
| End-to-end cycle, `bash fetch_lyrics.sh` (8 runs) | 0.28–0.34 s wall, ~0.23 s CPU |
| Python start + imports (`requests`, `tomllib`, …) | ~76 ms warm (~130 ms cold subprocess) |
| `get_player()` — 3 × `playerctl` (status, artist, title) | 59–71 ms |
| `local_dir_reachable()` — `os.listdir()` of the 501-entry CIFS library | ~69 ms |
| `find_local()` + `read_lines_from()` (57-line `.lrc`) | < 1 ms |

**Correction to an earlier framing:** the NAS `os.listdir()` is *not* the dominant cost. It
is one of three comparable pieces (Python startup, playerctl spawns, listdir), roughly a
fifth to a quarter of the cycle each. An earlier 0.20 s figure came from a *local*
scratch library, where listdir is free; the 0.3 s figure above is the real-NAS number.
The listdir is still the piece that touches the network on every cycle, and
`local_dir_reachable()` runs on every playing cycle even when the result cannot change.

Across the two live loops that is roughly **9% of one core continuously while any player
is active**, all of it re-deriving "same track, same lyrics" every 5s. An event-driven
design does this work once per track change instead of ~48 times per loop for a 4-minute
track.

A second steady-state benefit: consumers currently show "Searching…" for up to one poll
interval after a track change (`msc.lua` in clean-suite-e compares `lyrics.json`'s track to
the live `playerctl` track and reports `searching` when the provider lags). Event-driven
turns that from up to 5s into sub-second.

### Secondary: idle cost

With no player running, the pre-stopgap cycle still paid for Python start, the `requests`
import, a `playerctl status` shell-out, and two file rewrites (15 `execve`s per cycle):

| Idle cycle | Wall | CPU |
| --- | --- | --- |
| Before stopgap | 150–210 ms | 0.15–0.20 s (~3.2% of a core per loop, ~7% across two) |
| After stopgap (shipped) | ~39 ms | ~0.02 s (~0.8% across two loops) |
| Event-driven listener, idle | — | 0.0 ms over 30s |

The stopgap took most of the idle problem off the table; it does nothing for the
steady-state cost above. That is why steady-state, not idle, is the case for this work.
(It briefly made playing cycles ~30 ms slower — 296 → 327 ms — by querying `playerctl
status` twice; the status is now handed through to Python and playing cycles are back at
the original ~297 ms. See [Stopgap already shipped](#stopgap-already-shipped).)

---

## Feasibility findings

### Stock `playerctl --follow` is not zero-cost

It blocks rather than polling, but it subscribes to every `NameOwnerChanged` on the session
bus, not just MPRIS names, and this session bus is busy (~14 name changes per second
sampled over 20–25 s, unique names past `:1.262000` after 8.5 h uptime; source not
attributed — the media poll loops themselves account for only about 1 per second of it).

| | Idle CPU over 30 s | Voluntary context switches |
| --- | --- | --- |
| `playerctl --follow status`, no player | 33.9 ms (0.11% of a core) | 534 (~17/s) |
| Gio listener with daemon-side filters | 0.0 ms | 6 |

Behavior differences from poll semantics, observed with two mock MPRIS players:

- It follows the **first** player only. A second player's events are ignored.
- On the followed player exiting it prints a **blank line** and does **not** fall back to a
  still-running second player until that player's next event — while `playerctl status`
  (what the poll uses) reports the second player immediately.
- Player appearance, pause/resume, and track change each emit a line, as expected.

Consequence: even if it were used, events must be a *trigger*, with the state re-queried
via `playerctl status`/`metadata` (poll semantics), never a payload.

### Filtered Gio listener — the recommended mechanism

Subscribe with match rules the bus daemon applies itself, so the process wakes only for
MPRIS traffic:

```python
#!/usr/bin/env python3
# Tested prototype: daemon-side match rules only.
import time, gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
def emit(kind, *a): print(f"{time.strftime('%H:%M:%S')} {kind}", *[str(x)[:70] for x in a], flush=True)
# NameOwnerChanged only for names under org.mpris.MediaPlayer2.* (arg0namespace filter)
bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
    "/org/freedesktop/DBus", "org.mpris.MediaPlayer2", Gio.DBusSignalFlags.MATCH_ARG0_NAMESPACE,
    lambda c, s, p, i, sig, params: emit("name", *params.unpack()))
# PropertiesChanged on the MPRIS object path, any sender
bus.signal_subscribe(None, "org.freedesktop.DBus.Properties", "PropertiesChanged",
    "/org/mpris/MediaPlayer2", None, Gio.DBusSignalFlags.NONE,
    lambda c, s, p, i, sig, params: emit("props", s, params.unpack()[0], list(params.unpack()[1].keys())))
GLib.MainLoop().run()
```

Measured: 0.0 ms CPU and 6 context switches over 30 s idle; ~21 MB resident (versus ~6 MB
for `playerctl`). Against a mock player it emitted exactly the expected events: name
appears, `PropertiesChanged` (`PlaybackStatus`), `PropertiesChanged` (`Metadata`), name
disappears.

Note `dbus-python` is **not** a substitute: its `add_signal_receiver` has no
`arg0namespace` keyword (the first prototype crashed on it). Gio is the tested route;
`add_match_string` on `dbus-python` was not tried.

### What was not tested

Stated so the build phase doesn't assume otherwise:

- Only a **mock** MPRIS player (a ~35-line `dbus-python` service) was used. No real player
  (Spotify, Firefox, VLC, Rhythmbox, mpv-mpris) was exercised, so real-world signal
  burst shape, `Position`/`Seeked` behavior, and player-specific quirks are unknown.
- Multi-player behavior was observed only with two mocks.
- The bus is `dbus-daemon`; `dbus-broker` support for `arg0namespace` match rules was not
  checked.
- No long-run soak, no bus-restart or suspend/resume behavior, no behavior when
  `DBUS_SESSION_BUS_ADDRESS` is absent.
- Whether `playerctld` is in use was not checked.
- The mock player, listener, and an offline multi-cycle harness lived in a session scratch
  directory and were not preserved; the listener above is the tested prototype. (The
  multi-cycle harness for the throttle bug is preserved in the
  [bug doc](2026-09-20-lyrics-publish-then-searching-bug.md#reproduction).)
- **How to test any of this without a real lookup** — see the standing note below. It
  exists because an earlier round of this investigation got it wrong.

#### Testing this domain safely

**Standing rule: no test or mock player may ever reach the online-lookup path.** The
provider treats any player on the session bus as real. On 2026-09-20 a mock MPRIS player
reporting "Artist1 - Title1" ran on the *real* session bus while the two live media loops
(`media = true`, `enable_online = true`) were polling; they did what they are built to do
and made one real lookup pass (lrclib, lyrics.ovh) for the fake track. The result was a
miss — nothing was written to the library and no data of value left the machine — so it
was harmless. It is still a direct instance of the exposure `media = false` is the default
to protect against (listening metadata sent to third parties, and a hit would have written
a junk file into the real NAS library), and nothing in the provider would have prevented a
worse test track.

Ways to test, in order of preference:

1. **Isolate the bus.** Run every mock-player test under `dbus-run-session -- <test>`. The
   live loops and every real player sit on the real session bus and never see the private
   one. Verified 2026-09-20: `playerctl` inside the private bus saw the mock; a watcher on
   the real bus saw zero `org.mpris.MediaPlayer2` name events during the test.
2. **Disable the online path in the test's own config.** Point `GTEX62_CONFIG_DIR` at a
   scratch `site.toml` with `enable_online = false` and `GTEX62_CACHE_DIR` at a scratch
   cache, so a mis-wired test can neither look anything up nor touch live cache files. Use
   a scratch `local_dir` unless the test is deliberately read-only against the NAS.
3. **Stub the network at the function boundary** for logic tests (`fetch_online`,
   `is_offline`), as the throttle-bug harness does.
4. **Only if the live bus is unavoidable** (checking the real loops end to end): use a
   track that already exists in the library — a local hit returns before the online
   section — confirm `local_dir` is reachable immediately beforehand, and keep the window
   short. The residual risk is real: a NAS hiccup mid-window sends that track to the
   online path. Prefer 1 and 2.

For the eventual event-driven implementation: build its test harness around a private bus
from the start, and consider a hard guard in the provider — `playerctl` exposes the player
name (`{{playerName}}`), so online lookups could be refused for players whose name carries
a reserved test prefix. That is an untested idea and only protects mocks that follow the
naming rule, so it backs up rule 1 rather than replacing it.

---

## Candidate process shape (not decided)

Keep `fetch_lyrics.sh`/`.py` as the stateless unit of work, unchanged. Add a long-running
listener that decides *when* to run it:

1. Subscribe to the MPRIS signals above (before anything else — see Q5).
2. On any event, mark dirty and start a short trailing debounce (see Q2).
3. When the debounce fires and no fetch is in flight, clear dirty and run one fetch cycle;
   if dirty was set again during the run, run again afterwards (see Q1).
4. Watch the Conky PID for exit and shut down (see Q3).

In the launcher this is a new wiring form beside `initial_refresh`/`refresh_loop` — call
it `event_loop` here — with its own supervision (Q4) and its own singleton story (Q6).

---

## Core open questions

Every item below is a problem the current stateless poll model never has to handle,
found by reading `bin/gtex62-core-launch` against the measured behavior above.

### Q1. Skip-if-locked drops events (needs a dirty-flag re-run)

`run_locked` does `if mkdir "$lock_dir"; then ...; fi` with no `else`. If a fetch is in
flight (an online fetch can take 8 s per provider) when the next event arrives, that
event is **silently dropped**. Under polling the next tick heals it; under events there is
no next tick, so a track change during a slow fetch leaves `lyrics.json` about the wrong
track until some later event.

Needed: a dirty flag — an event during a run sets it, and the listener re-runs once the
current run finishes, coalescing any number of events into one re-run. The run/dirty state
belongs in the listener, not in `run_locked`'s mkdir lock.

### Q2. Debouncing multiple signals per track change

A single track change produced several `PropertiesChanged` signals from the mock
(separate `PlaybackStatus` and `Metadata` emissions); real players are known to emit more
(`Position`, `CanGoNext`, art URL updates), sometimes out of order, and metadata can
arrive after status.

Needed: a trailing debounce window (a few hundred ms is the starting guess — unvalidated)
so one track change produces one fetch cycle, with a re-query of `playerctl` at fire time
rather than trusting signal contents. Open: whether the window should be longer for
metadata-arrives-late players, and how it interacts with Q1's dirty flag.

### Q3. Orphaned-listener detection (needs `pidfd_open` on the Conky PID)

`refresh_loop` checks `kill -0 "$CONKY_PID"` every cycle and exits when Conky is gone, so
a `SIGKILL`ed launcher self-heals within one interval. `cleanup()` also only kills the
loop *subshell* PID — short-lived children are fine with that; a blocking listener child
would be **orphaned**. A listener that only wakes on MPRIS events would not notice Conky
died until the next event, and with no player running that could be never.

Needed: the listener watches the Conky PID itself with zero polling —
`os.pidfd_open(CONKY_PID)` added to the GLib main loop (Linux ≥ 5.3, Python ≥ 3.9;
readable when the process exits) — and additionally `cleanup()` must stop the listener
explicitly (or run it in its own process group and kill the group).

### Q4. Restart-on-crash supervision

A crashed poll is repaired by the next tick. A crashed listener stays dead: no updates,
and nothing in the current model restarts anything.

Needed: a supervisor — a bounded-backoff restart loop in the launcher, or a `systemd --user`
unit (core already ships timers; see `systemd/`). Related: "alive and idle" and "dead"
must be distinguishable — with events, an unchanged `generated_at` no longer implies a
problem, so Doctor needs a liveness check (pidfile/process) for MEDIA instead of relying on
age. Doctor already treats MEDIA as a timestamp-group domain with no countdown TTL
([doctor-design.md](doctor-design.md)), so this is an addition, not a contradiction.

### Q5. Startup ordering (subscribe, then fetch)

If the listener does its initial fetch and *then* subscribes, an event in the gap is lost.
If it subscribes first, an event can arrive before the initial fetch finishes — which Q1's
dirty flag already handles.

Needed: subscribe → initial fetch → enter event loop. Also open: the session bus must be
reachable at launch (autostart/`systemd --user` contexts export it; other launch paths may
not), and what to do on bus disconnect or restart (re-subscribe, then a full re-fetch,
since events during the outage are unrecoverable).

### Q6. Duplicate listeners across suites sharing one domain

Today two suites (`osa`, `sitrep`) each run their own media loop, both writing the same
`shared/media/local/` files; `run_locked` serializes them through a shared lock name
(`media-local`) so the cost is duplicated polling, not corruption. Pidfiles are per-suite
(`${SUITE_ID}-media-refresh.pid`) and each suite's `cleanup()` kills only its own.

Two listeners would double every fetch cycle (serialized, so harmless but wasteful); a
single shared listener needs a singleton (lock/lease in `runtime/locks`, takeover if the
holder dies) **and** an ownership rule so one suite exiting does not kill the listener
another suite still depends on. Open: singleton-with-takeover versus accepting duplicates
(simplest; matches today's behavior; doubles the per-event cost, which is small).

---

## Further questions (found while writing, not part of the six)

- **Scope of the listener.** The lyrics provider only needs *track-change* events. Consumers
  (`msc.lua`, tech-hud `music.lua`) also shell out to `playerctl` at draw time for
  position, volume, and cover, and event-driven MEDIA lyrics does nothing about that.
  Whether the listener should also publish a player-state file (`player.json`) is a scope
  question — the lyrics design doc deliberately split "media domain (player status, cover
  art)" from the lyrics library.
- **New dependency.** The Gio listener needs `python3-gi` (present on this machine).
  `core-launcher-design.md` already lists per-domain tool checks for Doctor; this would
  be a new one for `media`. A parsed `dbus-monitor`/`busctl monitor` route with the same
  match rules would avoid it and was not tried beyond confirming `dbus-monitor` accepts
  match rules.
- **Mode/config surface.** Likely `[media.lyrics] mode = "poll" | "events"` in
  `site.toml`, defaulting to `poll`, with the listener falling back to poll when the
  session bus is unavailable. `poll_interval_sec` would keep its meaning in `poll` mode.
  Not decided.
- **Unguarded `requests` import** (already recorded in
  [doctor-design.md](doctor-design.md)): the stopgap means an idle cycle no longer imports
  it, so the failure now appears only once a player is active — arguably harder to notice.
  Independent of this design.

---

## Related, but independent: publish-then-searching bug

Found while checking whether event-driven would remove it, and filed as its own bug —
**[2026-09-20-lyrics-publish-then-searching-bug.md](2026-09-20-lyrics-publish-then-searching-bug.md)** —
because it violates an explicit requirement of [lyrics-library-design.md](lyrics-library-design.md#failure-handling)
("not a blank widget") and should be fixed regardless of polling model. In short: after an
online fetch whose library write fails or is skipped, the widget blanked on five of every
six poll cycles and the provider re-queried the network every 30 s. **Status: resolved** — the
fetched lyrics are now held between cycles, served without re-fetching, never downgraded by a
failed lookup or by being offline, and the skipped library write is retried from the stored
text (see the bug doc).

That makes the fix independent of the polling model: event-driven refresh would only have
*masked* the bug (no re-poll, no second cycle — but any later event for the same track inside
30 s, such as a pause/resume, re-entered the same branch), and now there is nothing to mask.

---

## Stopgap already shipped

`providers/media/fetch_lyrics.sh` now runs `timeout 5 playerctl status` first; when
nothing is Playing/Paused it writes the identical "inactive" pair (`lyrics.json`,
`status.json`) from bash and exits without starting Python. It falls through to Python on
any doubt (odd profile id, write failure), so `fetch_lyrics.py` remains the source of
truth. Verified byte-identical to the Python path for: no player, `playerctl` missing,
status `Stopped`, hung `playerctl` (5 s cap either way), player playing, and player paused;
and live against the real cache and NAS (idle, a library track playing, player exit).
Idle cost: ~176 ms → ~39 ms wall.

The first version made playing cycles ~30 ms slower (a second `playerctl status`, one from
bash and one from Python). Fixed: the wrapper passes the status it already read to Python
in `GTEX62_MEDIA_PLAYER_STATUS`; `fetch_lyrics.py` uses it when set and asks for itself
when not (direct invocation, or the wrapper bailed before asking). Playing cycle against
the real NAS, interleaved A/B over 15 runs × 2 rounds: original 298/297 ms, first
fast-path 321/323 ms, with hand-off 302/294 ms; `playerctl` execs per playing cycle
3 / 4 / 3. Idle stays ~38 ms.

Independent of `media = false` in `core.toml.example`: that default exists because the
network fetches and NAS write-through happen per track once a player runs, regardless of
polling or events. Neither the stopgap nor this design changes when those happen, so
neither changes the default.

---

## Suggested phasing

1. **Done:** idle fast-path.
2. **Done:** the publish-then-searching bug ([bug doc](2026-09-20-lyrics-publish-then-searching-bug.md)).
3. Prototype the listener against **real players** (Spotify, a browser, VLC, mpv-mpris,
   Rhythmbox), including two at once, and record burst shape — this decides Q2's window
   and whether follow-mode's multi-player quirks matter for a re-querying design.
4. Decide the process shape and Q3/Q4/Q6 (supervisor, singleton) before any launcher
   change; these are the parts with no precedent in the codebase.
5. Implement behind a config switch defaulting to today's poll, with Doctor liveness for
   the listener.

## Verification plan (for the build phase)

Same style as the lyrics domain's own verification — synthetic scenarios first, then live:

- Event for a track change during an in-flight slow fetch: `lyrics.json` ends about the
  *new* track (Q1).
- Burst of signals for one track change: exactly one fetch cycle (Q2).
- `SIGKILL` the launcher with no player running: listener exits without an event (Q3).
- `kill -9` the listener: restarted with backoff; Doctor shows the outage (Q4).
- Player already running when the listener starts, and event between subscribe and first
  fetch: no lost update (Q5).
- Two suites launched, then one stopped: the other keeps updating (Q6).
- Session bus unreachable at launch and mid-run: defined fallback, no busy loop.
- Idle CPU/wakeups re-measured at 30 s and over an hour, against the numbers above.
