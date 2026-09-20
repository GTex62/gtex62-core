# Bug: lyrics widget blanks after a successful fetch when the library write fails or is skipped

| | |
| --- | --- |
| **Status** | **RESOLVED 2026-09-20.** Fix is in the working tree (uncommitted when this was written); it closes the blank widget, the periodic re-fetch, and the destructive failed-re-fetch path. Intentional boundaries are listed under [Behavior boundaries](#behavior-boundaries-intentional). |
| **Component** | `providers/media/fetch_lyrics.py` (`media` domain) |
| **Found** | 2026-09-20, while checking whether an event-driven MEDIA refresh ([media-event-driven-design.md](media-event-driven-design.md)) would remove it |
| **Present since** | the initial implementation, `47efcb2` (2026-08-25) — the throttle branch and its `searching` publish were in the first version of the file |
| **Requirement violated** | [lyrics-library-design.md § Failure Handling](lyrics-library-design.md#failure-handling): "the widget should show lyrics even if the library write failed … a temporary NAS outage costs a re-fetch next time, **not a blank widget**." |

This was a bug, not accepted behavior: the design doc states the outcome explicitly and the
provider did not deliver it. It is filed separately from
[lyrics-library-design.md](lyrics-library-design.md) on purpose — that document is the spec
and keeps saying what the behavior *must* be; nothing in it was changed to fit the code.

---

## Symptom

After a successful online fetch whose library write-through is **skipped** (`local_dir`
unreachable, e.g. NAS down), **fails** (read-only or permission error), or **disabled**
(`enable_local = false`), the provider published the fetched lyrics for exactly one cycle.
Every following cycle within `FETCH_THROTTLE_SEC` (30 s) overwrote `lyrics.json` with
`state: "searching"` and empty `lines`. After 30 s it re-fetched from the network, published
lyrics for one cycle, and blanked again — for as long as the track played. At the default 5 s
poll, lyrics were visible one cycle in six, and the network was queried every 30 s.

Two consequences turned out to be worse than the blanking:

- **A failed periodic re-fetch destroyed lyrics already in hand.** A re-fetch that returned
  nothing published `not_found` with no lines and recorded `last_result = "miss"` for 12 h
  (`MISS_RETRY_SEC`) — one transient network failure at the wrong moment lost lyrics the
  provider already had, for the rest of the track.
- **Being offline blanked them too.** The `enable_online`/`is_offline` checks run before the
  same-track branch, so an internet drop while the NAS was down published `offline` with no
  lines over lyrics that had been fetched successfully minutes earlier.

## Root cause

`lyrics.json` is rewritten every cycle, and each invocation is a fresh process. The state
file (`lyrics_state.json`) held throttle bookkeeping (`last_track_key`, `last_result`,
`last_fetch_time`, …) but **not the fetched lines**. When the write-through produced no
library file, the next cycle's local lookup found nothing, fell to the online section, saw the
same track key with `last_result == "hit"` inside 30 s, and took the throttle branch — which
had nothing to publish except `searching`; after 30 s it simply asked the network again.

In the tech-hud reference this branch was effectively unreachable after a hit: a failed
library write counted as a *miss* (it never displayed text it had not saved), and after a
successful write the next draw found the file. Core added the "publish even if the write
failed" path per the design doc, but the cycles *after* the publishing one were never
exercised — the design doc's verification section covers single-cycle behavior only.

## Reproduction

Offline: player and network stubbed, virtual clock at 5 s polls, no repo edits, no egress.
Save as a script and run (`python3 repro.py`):

```python
import importlib.util, json, os, sys, tempfile, time as _rt
root = tempfile.mkdtemp()
os.makedirs(root + "/cfg")
open(root + "/cfg/site.toml", "w").write('[media.lyrics]\nlocal_dir = "/nonexistent/NAS"\nenable_online = true\n')
os.environ.update(GTEX62_CONFIG_DIR=root + "/cfg", GTEX62_CACHE_DIR=root + "/cache")
sys.argv = ["fetch_lyrics.py", "local"]
spec = importlib.util.spec_from_file_location(
    "fl", os.path.expanduser("~/.config/conky/gtex62-core/providers/media/fetch_lyrics.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
clock = [1_800_000_000.0]
class FT:  # virtual clock; everything else passes through
    def __getattr__(self, n): return getattr(_rt, n)
    def time(self): return clock[0]
m.time = FT()
fetches = [0]
def fake_fetch(*a):
    fetches[0] += 1
    return "line one\nline two", "txt", "stub"
m.get_player = lambda: ("Playing", "Art", "Title")  # no real player
m.is_offline = lambda p: False                       # no network
m.fetch_online = fake_fetch
m.OUT_DIR.mkdir(parents=True, exist_ok=True)
print("t(s) state lines fetches")
for i in range(14):
    m.main()
    d = json.load(open(m.LYRICS_JSON))
    print(i * 5, d["state"], len(d["lines"]), fetches[0])
    clock[0] += 5
```

The script needs no player and no bus. For any test that *does* use a mock player, follow
[media-event-driven-design.md § Testing this domain safely](media-event-driven-design.md#testing-this-domain-safely)
(private `dbus-run-session` bus, scratch config with `enable_online = false`).

| Scenario | Before the fix (`lyrics.json` over 65 s) | After the fix |
| --- | --- | --- |
| Control: writable, reachable library | `ok` every cycle, 1 fetch | unchanged |
| `local_dir` unreachable | `ok` at 0/30/60 s, `searching` (0 lines) between, 3 fetches | `ok` with lines every cycle, **1 fetch** |
| `local_dir` read-only | same as unreachable | `ok` with lines every cycle, 1 fetch |
| `enable_local = false` | same as unreachable | `ok` with lines every cycle, 1 fetch |

## Fix (as applied)

The provider keeps the last online hit in a sidecar, `shared/media/<profile>/lyrics_last_hit.json`
(`key`, `provider`, `write_note`, `lines`, `format`, `library_path`, plus the **raw** fetched
`text` and an `in_library` flag), written best-effort after every online hit
(`save_last_hit`). In `main()`, right after the local-library lookup misses and **before** the
online-disabled, offline, and re-fetch branches, `load_last_hit(key)` is consulted:

- **Held lyrics are served, and the network is not asked.** If a sidecar exists for the current
  track and the library can't be the source (`in_library` is false, or the library is
  unreachable now), its lines are published as `state: "ok"` (status note
  `re-published held lyrics (no re-fetch)`). Nothing about the situation has changed since the
  fetch that succeeded, so there is nothing to ask lrclib/lyrics.ovh — the 30 s re-fetch is
  gone, not just its blank.
- **A held-good result is never downgraded.** Because the check sits ahead of every branch that
  could publish a degraded state, neither a failed re-fetch (none is attempted), nor being
  offline, nor `enable_online = false` can replace held lyrics. They are replaced only by a
  successful fetch for a *different* track, or superseded by a library file appearing (the local
  lookup runs first).
- **The library write is retried from the stored raw text** whenever the library is reachable
  and writable again (`write_through`, so still create-only and race-safe), at most once per
  `FETCH_THROTTLE_SEC` so a permanently read-only library isn't hit every cycle. The published
  `lines` are the display-stripped copy; the file written is the raw text (LRC timestamps
  intact), identical to what a normal write-through would have produced. Once it lands, the next
  cycle is an ordinary local hit.

### Why the write-through retry was required, not deferrable

Closing the first two points alone (stop re-fetching, never downgrade) gets the widget right —
but it removes the only thing that ever put such a track into the library once the NAS came
back. Measured with the offline harness, same scenario (fetched while the NAS was down, then the
NAS returns while the track keeps playing and is replayed an hour later):

| Code | Widget | Library file after NAS returns | Fetches |
| --- | --- | --- | --- |
| Original | blank 5 cycles in 6 | written (the 30 s re-fetch wrote it, as a side effect) | 2 |
| Fix without retry | correct | **never written** (still absent after 2 min and after replay) | 1 |
| Fix with retry (final) | correct | written on the next cycle after the NAS returns | 1 |

So dropping the re-fetch without the retry would have been a regression against even the
original behavior. The retry is about 15 lines and reuses `write_through()` unchanged.

## Behavior boundaries (intentional)

- **Deliberately removing a library file still forces a re-fetch.** If the track *was* in the
  library (`in_library`), the library is reachable, and the file is gone, the held copy is not
  used — that is a removal, and "delete the wrong lyrics to get a fresh lookup" must keep
  working. It falls through to a normal lookup; if *that* fails, the result is `not_found` as it
  always was for a track with no held copy.
- **One slot.** The sidecar holds only the most recent fetched track. A successful fetch for
  another track replaces it, so returning to the first track with the network still failing
  gives `not_found`. A failed lookup for another track does *not* replace it.
- **Held lyrics are served, not refreshed.** While a track's lyrics can't be kept in the
  library, a replay of that same track is served from the sidecar without a lookup. With
  `enable_local = false` (no library at all) the sidecar therefore acts as a one-track cache in
  the ephemeral cache directory; deleting `lyrics_last_hit.json` forces a fresh lookup.
- **Degrades to the old behavior, never crashes.** A missing, corrupt, empty, or other-track
  sidecar falls through to the previous logic (`searching` inside the throttle window, then a
  lookup). A sidecar written by the earlier partial fix (no raw text) is served but can't drive a
  write retry.
- **Not part of this bug, noted so it isn't lost:** a transient network failure on a *first*
  lookup (nothing held yet) is cached as a miss for 12 h — inherited from the tech-hud reference.
  This fix protects results already in hand; it does not change that path.

## Verification

Offline harness (virtual clock at 5 s polls; player, network and NAS stubbed; throwaway
config/cache/"NAS" directories; no player, no bus, no egress) — **35 checks across 9 scenarios,
all passing**:

| Scenario | What it proves |
| --- | --- |
| NAS returns | widget populated throughout; library written once the NAS is back with no re-fetch; 1 fetch total |
| Four configs, 2 min | unreachable / read-only / `enable_local = false` / control: `ok` + lines every cycle, 1 fetch each (was 3 per 65 s); read-only write retries bounded |
| **Fail → success → fail again** | miss (NAS down) → `not_found`; 12 h later a fetch succeeds → held; then the network "failing" again at +31 s, +1 h, +13 h is never attempted and lyrics keep being served; offline and `enable_online = false` don't blank them; NAS returns → raw text written to the library (timestamps intact), next cycle a normal local hit; NAS gone again → still served; file deleted with NAS up → normal re-fetch and re-write; **0 network fetches after the successful one** |
| Deleted file, failed re-fetch | boundary above: treated as a fresh lookup |
| Track changes | B never shows A's lines; A's held copy survives B's failed lookup; single-slot replacement behaves as documented |
| Degrade | sidecar missing / corrupt / other-track → `searching`, no crash |
| Miss / instrumental | unchanged (cached miss, no re-fetch; instrumental state) |
| Retry recovers | read-only → writable: retries throttled (3 attempts in ~75 s), then succeeds |
| Previous partial-fix sidecar | served without crashing; no retry possible, nothing written |

Regression, unchanged paths (private `dbus-run-session` bus, scratch cache, `enable_online = false`):
original Python and current Python produce identical `lyrics.json`/`status.json` for no player,
playing and paused with a real NAS-library track, and a track absent from the library. Timing:
idle cycle 175 → 39 ms; playing local-hit cycle unchanged (298 → 300 ms) — the held-lyrics check
only runs after a local miss.

**Not done:** a live check. The live loops reach this code only during a real NAS outage with a
real online fetch, and provoking one would mean a real lookup of a real track — not worth it for
what the harness already exercises. The harness itself lived in a session scratch directory and
is not preserved beyond the reproduction above.
