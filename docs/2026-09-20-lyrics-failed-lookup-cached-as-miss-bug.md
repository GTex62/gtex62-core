# Bug: a failed online lookup is cached as "no lyrics exist" for 12 hours

| | |
| --- | --- |
| **Status** | **OPEN** — not fixed; tracked here so it is not left as a passing mention. No fix is scheduled. |
| **Component** | `providers/media/fetch_lyrics.py` (`media` domain): `fetch_lrclib()`, `fetch_lyrics_ovh()`, `fetch_online()`, and the miss branch of `main()` |
| **Found** | 2026-09-20, while closing [2026-09-20-lyrics-publish-then-searching-bug.md](2026-09-20-lyrics-publish-then-searching-bug.md) (its "worse residual" was this path, reached from a different direction) |
| **Present since** | the initial implementation, `47efcb2` (2026-08-25), **inherited from the tech-hud reference** — see [Origin](#origin) |
| **Requirement violated** | None stated outright. It contradicts the principle [lyrics-library-design.md § Failure Handling](lyrics-library-design.md#failure-handling) states for `local_dir` — "do not treat an unreachable directory as 'no lyrics exist'" — which applies equally to the network: a lookup that *failed* is not evidence that no lyrics exist. It is also a silent gap in the sense of the 0.7.0 CHANGELOG entry: a domain reporting `state: "ok"` while something underneath it was wrong. |

Filed separately from the resolved
[publish-then-searching bug](2026-09-20-lyrics-publish-then-searching-bug.md) on purpose: that
fix protects lyrics the provider **already has**; this bug is about a track where a lookup
failed and nothing was ever held, which that fix does not touch.

---

## Symptom

When every online provider fails to return lyrics for a track, the provider publishes
`state: "not_found"` and records `last_result = "miss"`. For the next 12 hours
(`MISS_RETRY_SEC`) it will not look that track up again — it publishes `not_found` from the
cached result without contacting any provider. That is the right behavior when the providers
*answered* "we don't have it". It is wrong when they *failed*: a timeout, a connection error, a
rate-limit or server-error response, or a malformed reply is recorded as the same
`last_result = "miss"`, so one transient failure at the wrong moment makes a track that has
lyrics show "not found" long after the network has recovered.

The widget and `status.json` give no way to tell the two apart (`status.json` says `ok` /
`miss`), so nothing surfaces the problem to the user or to Doctor.

## Root cause

Both provider functions collapse every kind of failure into the same `None` they return for
"no lyrics":

- `fetch_lrclib()` returns `None` for **any** non-200 status (a genuine 404, but also 429, 500,
  503…), for `requests.RequestException` (timeout, connection error, DNS), and for `ValueError`
  (invalid JSON).
- `fetch_lyrics_ovh()` does the same.
- `fetch_online()` returns `(None, None, None)` when no provider gave a result, without saying
  whether any of them failed rather than answering.
- `main()` treats that as a definitive miss (`state["last_result"] = "miss"`), and the same-track
  branch honors it for `MISS_RETRY_SEC` (12 h).

The only guard is `is_offline()` — a 2 s TCP probe to `1.1.1.1:443` plus a DNS lookup of the
provider hosts — which turns a *total* connectivity loss into the uncached `offline` state. It
does not cover a provider being down, slow (each request has an 8 s timeout), rate-limiting, or
returning an error, nor the network dropping between the probe and the request.

## Origin

Inherited, not introduced by the port. The tech-hud reference
(`gtex62-tech-hud/lua/widgets/music.lua`) fetches with `curl -fsSL --max-time 8` — `-f` makes an
HTTP error produce no output — and returns `nil` on empty output, exactly the same collapse,
then records `last_result = "miss"` and honors it for `MISS_RETRY_S = 12 * 60 * 60`. The core
design doc promoted that logic "not a redesign", and the throttle/miss state-machine math was
verified against the 30 s and 12 h boundaries, but never against a failed lookup.

One difference made the port stickier: the reference kept that state in the Lua process, so a
Conky restart cleared it. Core keeps it in `lyrics_state.json` in the cache directory, and
nothing at launch or bootstrap clears it (checked in `gtex62-core-launch` and
`gtex62-core-bootstrap-runtime`), so the cached miss survives a launcher restart.

## Reproduction

Offline: player and `is_offline()` stubbed, virtual clock, **and only `requests.get` stubbed** —
the real `fetch_lrclib()`/`fetch_lyrics_ovh()`/`fetch_online()` code runs. No repo edits, no
egress. Save as a script and run (`python3 repro.py`):

```python
import importlib.util, json, os, sys, tempfile, time as _rt
import requests
root = tempfile.mkdtemp()
os.makedirs(root + "/cfg")
open(root + "/cfg/site.toml", "w").write('[media.lyrics]\nenable_local = false\nenable_online = true\n')
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
title, mode, calls = ["A"], ["timeout"], [0]
m.get_player = lambda: ("Playing", "Art", title[0])  # no real player
m.is_offline = lambda p: False                       # the offline probe passes: network is "up"
class Resp:
    def __init__(self, code, body=None): self.status_code, self._b = code, body or {}
    def json(self): return self._b
def fake_get(url, **kw):  # only requests.get is stubbed; the real fetch_lrclib/fetch_lyrics_ovh run
    calls[0] += 1
    if mode[0] == "timeout": raise requests.Timeout()
    if mode[0] in ("404", "503"): return Resp(int(mode[0]))
    return Resp(200, {"syncedLyrics": "[00:01.00]line one", "lyrics": "line one"})
m.requests.get = fake_get
m.OUT_DIR.mkdir(parents=True, exist_ok=True)
def cycle(label, adv=5):
    m.main()
    d = json.load(open(m.LYRICS_JSON)); st = json.load(open(m.STATUS_JSON))
    print(f"  {label:<34} {d['state']:<10} lines={len(d['lines'])} requests={calls[0]:<2} status={st['note']!r}")
    clock[0] += adv
def fresh():
    for f in (m.STATE_JSON, m.LAST_HIT_JSON):
        if f.exists(): f.unlink()

print("A. Both providers time out once; the network is fine again 5 s later")
cycle("t0        lookup, timeouts"); mode[0] = "ok"
for adv, label in [(5, "t+5s      network recovered"), (55, "t+1m"), (3540, "t+1h"), (39540, "t+12h (-1m)"), (60, "t+12h")]:
    clock[0] += adv - 5; cycle(label)
print("B. Same, but another track plays in between")
fresh(); title[0], mode[0], clock[0] = "A", "timeout", clock[0] + 100
cycle("A: lookup, timeouts"); mode[0] = "ok"; cycle("A: network recovered")
title[0] = "B"; cycle("B starts"); title[0] = "A"; cycle("A again")
print("C. What the widget/status show for a real not-found vs. a failure")
outs = {}
for md in ("404", "503", "timeout"):
    fresh(); title[0], mode[0], clock[0] = "C" + md, md, clock[0] + 100; m.main()
    d = json.load(open(m.LYRICS_JSON)); d.pop("generated_at"); d["track"] = None
    st = json.load(open(m.STATUS_JSON)); st.pop("generated_at")
    outs[md] = json.dumps([d, st], sort_keys=True)
print("  404 == 503 == timeout (lyrics.json + status.json identical):", len(set(outs.values())) == 1)
```

Output on the current code (2026-09-20):

```text
A. Both providers time out once; the network is fine again 5 s later
  t0        lookup, timeouts         not_found  lines=0 requests=2  status='miss'
  t+5s      network recovered        not_found  lines=0 requests=2  status='cached miss'
  t+1m                               not_found  lines=0 requests=2  status='cached miss'
  t+1h                               not_found  lines=0 requests=2  status='cached miss'
  t+12h (-1m)                        not_found  lines=0 requests=2  status='cached miss'
  t+12h                              ok         lines=1 requests=3  status='fetched via lrclib'
B. Same, but another track plays in between
  A: lookup, timeouts                not_found  lines=0 requests=5  status='miss'
  A: network recovered               not_found  lines=0 requests=5  status='cached miss'
  B starts                           ok         lines=1 requests=6  status='fetched via lrclib'
  A again                            ok         lines=1 requests=7  status='fetched via lrclib'
C. What the widget/status show for a real not-found vs. a failure
  404 == 503 == timeout (lyrics.json + status.json identical): True
```

What it shows:

- **A** — after one round of timeouts, zero further requests for 12 hours even though the network
  recovered 5 s in; the track is retried only at the 12 h mark.
- **B** — the damage is bounded by track changes: `fresh_state()` runs whenever a *different*
  track becomes current, so playing anything else and coming back retries immediately. In
  practice the wrong `not_found` lasts until a different track plays, not literally 12 hours —
  it is worst for a single track on repeat, a lone track with nothing queued after it, or a
  playlist where the affected track is replayed straight away.
- **C** — a real "not found" (404), a server error (503), and a timeout produce byte-identical
  `lyrics.json` and `status.json`.

## Scope and impact

- **Trigger needs a transient failure to land on a first lookup** — a track with no library file
  and nothing held — while `is_offline()` still passes. Provider-side errors and slow responses
  are the realistic cases. With the library populated (most tracks are local hits) and the
  fetch → write-through path succeeding, a track is looked up once ever.
- **Cost of a wrong miss:** the widget shows "not found" for lyrics that exist, with no
  indication it is transient.
- **Cost of the cache being removed naively:** a genuine miss cached for 12 h is intentional — it
  keeps the provider from hitting lrclib/lyrics.ovh every 30 s for a track they don't have. Any
  fix must keep that for *definitive* not-found answers.

## Proposed direction (not decided, not implemented)

1. **Make the fetchers tri-state:** hit / definitive not-found / error. Definitive not-found is a
   provider *answering* (lrclib's HTTP 404, lyrics.ovh's 404, or a 200 with no lyrics); error is
   anything else — timeout, connection error, other non-200 (429, 5xx), unparseable reply.
2. **Only cache the 12 h miss when every provider answered not-found.** If any provider errored
   and none hit, record a distinct short-retry result (e.g. `error`, retried on the existing 30 s
   throttle or a modest backoff) instead of `miss`. Skipping the 12 h cache on an error is what
   fixes this bug; the rest is presentation.
3. **Surface it.** `status.json` should say `degraded` (or equivalent) with a note naming the
   failed provider(s) — the same "no silent `ok`" principle as the 0.7.0 provider fixes — so
   Doctor and the user can see a failing provider instead of a plausible-looking "not found".
   While retrying, `lyrics.json` can reuse the existing `searching` state, which consumers such
   as `msc.lua` already handle; a *new* `state` value needs checking against every consumer first.

Open items before building:

- **Assumption to verify:** that lrclib and lyrics.ovh really answer an unknown track with an HTTP
  404 (as opposed to a 200 with empty lyrics, or some other status). Not verified — doing so needs
  a real request, so do it by hand with a made-up track name, never through the provider or the
  live loops (see the standing rule in
  [media-event-driven-design.md § Testing this domain safely](media-event-driven-design.md#testing-this-domain-safely)).
- **Mixed outcomes:** one provider 404s and the other errors — treat as uncertain (short retry),
  since the erroring provider might have had it.
- **Backoff shape** and whether the retry should count against `FETCH_THROTTLE_SEC` as it does today.

## Verification status

Reproduced offline with the script above (which runs the real fetch functions); the output block
is the current behavior. No live occurrence has been observed or searched for — the live loops
are only known to have made one lookup of a synthetic track during testing; it came back as a
miss, and the provider could not say whether that was a real "not found" — which is the bug. The check that nothing clears `lyrics_state.json` at launch was a grep of the launcher and
bootstrap scripts, not a restart test.
