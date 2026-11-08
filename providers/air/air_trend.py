# providers/air/air_trend.py
# One-hour and 24-hour change of the outdoor air readings the ENV panel shows, for its trend columns.
#
# Pure standard library, no I/O: fetch_air_extras.py keeps the state dict in a file and calls update() on every air refresh
# (about every 15 minutes), then compute() for extras.json. The values are the air provider's `selected` readings, the same
# ones the panel shows (nearest AirNow monitor where there is one, else OpenWeather's model).
#
# Each metric keeps its raw samples for 27 hours. "Now" is the newest sample (the sources report hourly at best, so there is nothing
# to smooth, and a median would drag in the older seeded samples); the comparison is the median of the samples within a window
# around one hour (or 24 hours) ago. A change under a per-metric floor is 0%; no sample in the
# comparison window (the provider was not running then) is None, never a guess. Readings are hourly at best, so changes show
# in steps.
#
# The display's HI and LO columns: the highest and the lowest reading of each pollutant over the last seven days. Each metric keeps the
# minimum and maximum of every clock hour for EXT_KEEP_S seconds (state["ext"]); folding the same reading in twice changes nothing, so the live
# readings and the sources' own history (air_backfill, hourly grid) can overlap. The window is whole hours: it starts at the hour that
# contains now - seven days.
import statistics

NOW_S = 2400
KEEP_S = 27 * 3600
EXT_BIN_S = 3600
EXT_KEEP_S = 7 * 86400
WINDOW_1H_S = 1200
WINDOW_24H_S = 1800
CAP_PCT = 999

# Smallest absolute change worth reporting, in each metric's unit (ug/m3).
FLOORS = {"pm2_5": 1.0, "o3": 3.0, "pm10": 1.0, "no2": 1.0, "so2": 1.0, "co": 30.0, "nh3": 0.5}
METRICS = tuple(FLOORS)


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def update(state, now, values):
    """Add one reading per metric (`values`: metric -> number or None). Returns the updated state dict."""
    st = state if isinstance(state, dict) else {}
    samples = st.setdefault("samples", {})
    for m in METRICS:
        v = _num((values or {}).get(m))
        if v is None:
            continue
        s = [x for x in samples.get(m, []) if 0 <= now - x[0] <= KEEP_S and x[0] != now]
        s.append([now, v])
        samples[m] = s
        _ext_add(st.setdefault("ext", {}), m, now, v)
    cutoff = int((now - EXT_KEEP_S) // EXT_BIN_S)
    for b in (st.get("ext") or {}).values():
        for k in [k for k in b if int(k) < cutoff]:
            del b[k]
    return st


def _median_near(samples, t, half):
    vals = [x[1] for x in samples if abs(x[0] - t) <= half]
    return statistics.median(vals) if vals else None


def _pct(now_v, then_v, floor):
    if now_v is None or then_v is None:
        return None
    if abs(now_v - then_v) < floor:
        return 0
    if then_v <= 0:
        return None
    p = (now_v - then_v) / then_v * 100.0
    return int(max(-CAP_PCT, min(CAP_PCT, round(p))))


def compute(state, now):
    """{metric: {"h1_pct": int|None, "h24_pct": int|None}} for every metric."""
    st = state if isinstance(state, dict) else {}
    out = {}
    for m in METRICS:
        s = (st.get("samples") or {}).get(m, [])
        recent = [x for x in s if 0 <= now - x[0] <= NOW_S]
        now_v = max(recent)[1] if recent else None
        out[m] = {
            "h1_pct": _pct(now_v, _median_near(s, now - 3600, WINDOW_1H_S), FLOORS[m]),
            "h24_pct": _pct(now_v, _median_near(s, now - 86400, WINDOW_24H_S), FLOORS[m]),
        }
    return out


def has_sample(state, t, half=1800):
    """True when any metric has a sample within `half` seconds of time t."""
    st = state if isinstance(state, dict) else {}
    return any(abs(x[0] - t) <= half for v in (st.get("samples") or {}).values() for x in v)


def backfill(state, grid, now):
    """Seed samples from past readings: grid is [(t, {metric: value})]. A time that already has a sample for that metric
    (within 7 minutes) is left alone, so the live loop's own readings win. Returns the state dict."""
    st = state if isinstance(state, dict) else {}
    samples = st.setdefault("samples", {})
    for t, vals in grid or []:
        if _num(t) is None or not 0 <= now - t <= KEEP_S:
            continue
        for m in METRICS:
            v = _num((vals or {}).get(m))
            if v is None:
                continue
            s = samples.setdefault(m, [])
            if not any(abs(x[0] - t) <= 420 for x in s):
                s.append([t, v])
    for m in samples:
        samples[m].sort()
    return st


def _ext_add(ext, m, t, v):
    """Fold one reading into the min/max of its clock hour."""
    hours = ext.setdefault(m, {})
    key = str(int(t // EXT_BIN_S))
    e = hours.get(key)
    if e:
        e[0], e[1] = min(e[0], v), max(e[1], v)
    else:
        hours[key] = [v, v]


def backfill_extremes(state, grid, now):
    """Fold past readings into the hourly min/max: grid is [(t, {metric: value})]. Safe to repeat with overlapping rows."""
    st = state if isinstance(state, dict) else {}
    ext = st.setdefault("ext", {})
    for t, vals in grid or []:
        if _num(t) is None or not 0 <= now - t <= EXT_KEEP_S:
            continue
        for m in METRICS:
            v = _num((vals or {}).get(m))
            if v is not None:
                _ext_add(ext, m, t, v)
    return st


def extremes(state, now):
    """({metric: {"hi": number|None, "lo": number|None}}, span_hours): the highest and lowest reading of the last seven days, and how many
    hours back the oldest stored hour reaches (at most 168)."""
    st = state if isinstance(state, dict) else {}
    first = int((now - EXT_KEEP_S) // EXT_BIN_S)
    out, oldest = {}, None
    for m in METRICS:
        hours = [(int(k), e) for k, e in ((st.get("ext") or {}).get(m) or {}).items() if int(k) >= first]
        if hours:
            out[m] = {"hi": round(max(e[1] for _, e in hours), 2), "lo": round(min(e[0] for _, e in hours), 2)}
            lo = min(k for k, _ in hours)
            oldest = lo if oldest is None else min(oldest, lo)
        else:
            out[m] = {"hi": None, "lo": None}
    span = 0 if oldest is None else min(168, int((now - oldest * EXT_BIN_S) // 3600) + 1)
    return out, span


def coverage_hours(state, now):
    """How many of the last 168 clock hours have a stored reading for any metric (a gap shows as fewer)."""
    st = state if isinstance(state, dict) else {}
    first = int((now - EXT_KEEP_S) // EXT_BIN_S)
    seen = {int(k) for b in (st.get("ext") or {}).values() for k in b if int(k) >= first}
    return len(seen)
