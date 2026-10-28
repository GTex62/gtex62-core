# providers/air/air_trend.py
# One-hour and 24-hour change of the outdoor air readings the ENV panel shows, for its trend columns.
#
# Pure standard library, no I/O: fetch_air_extras.py keeps the state dict in a file and calls update() on every air refresh
# (about every 15 minutes), then compute() for extras.json. The values are the air provider's `selected` readings, the same
# ones the panel shows (nearest AirNow monitor where there is one, else OpenWeather's model).
#
# Each metric keeps its raw samples for 27 hours. "Now" is the median of the last NOW_S seconds; the comparison is the median
# of the samples within a window around one hour (or 24 hours) ago. A change under a per-metric floor is 0%; no sample in the
# comparison window (the provider was not running then) is None, never a guess. Readings are hourly at best, so changes show
# in steps.
import statistics

NOW_S = 2400
KEEP_S = 27 * 3600
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
        recent = [x[1] for x in s if 0 <= now - x[0] <= NOW_S]
        now_v = statistics.median(recent) if recent else None
        out[m] = {
            "h1_pct": _pct(now_v, _median_near(s, now - 3600, WINDOW_1H_S), FLOORS[m]),
            "h24_pct": _pct(now_v, _median_near(s, now - 86400, WINDOW_24H_S), FLOORS[m]),
        }
    return out
