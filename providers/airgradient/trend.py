# providers/airgradient/trend.py
# One-hour and 24-hour change for the indoor readings, for the display's trend columns.
#
# Pure standard library, no I/O: the provider (fetch_airgradient.py) keeps the state dict in its own
# state file and calls update() on every good reading, then compute() for status.json.
#
# How it works: each metric keeps the raw samples of the last NOW_S seconds ("now" is their median) and
# a median per 10-minute bin for the last KEEP_S seconds. The change over an hour (or a day) is the
# "now" median against the median of the bin that contains now - 3600 (or - 86400). Medians, not single
# readings, because the particle counts swing 20% from one minute to the next. A change smaller than a
# per-metric floor is reported as 0%; a missing comparison bin (the provider was not running then, or
# had fewer than MIN_BIN_SAMPLES samples in it) is reported as None, never guessed.
import statistics

BIN_S = 600
NOW_S = 600
KEEP_S = 40 * 3600
MIN_NOW_SAMPLES = 3
MIN_BIN_SAMPLES = 4
CAP_PCT = 999

# Smallest absolute change worth reporting, in each metric's own unit.
FLOORS = {
    "co2_ppm": 10, "pm1_ugm3": 0.5, "pm25_ugm3": 0.5, "pm10_ugm3": 0.5,
    "pm03_per_dl": 50, "voc_index": 5, "nox_index": 1,
}
METRICS = tuple(FLOORS)


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def update(state, now, values):
    """Feed one reading (`values`: metric -> number or None). Returns the updated state dict."""
    st = state if isinstance(state, dict) else {}
    samples = st.setdefault("samples", {})
    accs = st.setdefault("acc", {})
    bins = st.setdefault("bins", {})
    idx = int(now // BIN_S)
    for m in METRICS:
        v = _num(values.get(m))
        if v is None:
            continue
        s = [x for x in samples.get(m, []) if 0 <= now - x[0] <= NOW_S] + [[now, v]]
        samples[m] = s
        acc = accs.get(m)
        if acc and acc["b"] != idx:
            if len(acc["v"]) >= 1:
                bins.setdefault(m, {})[str(acc["b"])] = [statistics.median(acc["v"]), len(acc["v"])]
            acc = None
        if not acc:
            acc = {"b": idx, "v": []}
        acc["v"].append(v)
        accs[m] = acc
    cutoff = int((now - KEEP_S) // BIN_S)
    for m, b in bins.items():
        for k in [k for k in b if int(k) < cutoff]:
            del b[k]
    return st


def _bin_value(st, m, t):
    """(median, from_ha) of the 10-minute bin that contains time t, or (None, False) when there is none or it is thin.
    from_ha is True for a bin that was filled from Home Assistant's history, not from the provider's own readings."""
    idx = int(t // BIN_S)
    b = (st.get("bins") or {}).get(m, {}).get(str(idx))
    if b and b[1] >= MIN_BIN_SAMPLES:
        return b[0], len(b) > 2 and b[2] == "h"
    acc = (st.get("acc") or {}).get(m)
    if acc and acc["b"] == idx and len(acc["v"]) >= MIN_BIN_SAMPLES:
        return statistics.median(acc["v"]), False
    return None, False


def _pct(now_v, then_v, floor):
    if now_v is None or then_v is None:
        return None
    if abs(now_v - then_v) < floor:
        return 0
    if then_v <= 0:
        return None
    p = (now_v - then_v) / then_v * 100.0
    return int(max(-CAP_PCT, min(CAP_PCT, round(p))))


def compute_with_sources(state, now):
    """(trend, from_ha): trend is {metric: {"h1_pct": int|None, "h24_pct": int|None}} for every metric; from_ha is True
    when at least one number shown was compared against a bin filled from Home Assistant's history."""
    st = state if isinstance(state, dict) else {}
    out, from_ha = {}, False
    for m in METRICS:
        recent = [x[1] for x in (st.get("samples") or {}).get(m, []) if 0 <= now - x[0] <= NOW_S]
        now_v = statistics.median(recent) if len(recent) >= MIN_NOW_SAMPLES else None
        cell = {}
        for key, lag in (("h1_pct", 3600), ("h24_pct", 86400)):
            then_v, ha = _bin_value(st, m, now - lag)
            cell[key] = _pct(now_v, then_v, FLOORS[m])
            if cell[key] is not None and ha:
                from_ha = True
        out[m] = cell
    return out, from_ha


def compute(state, now):
    """{metric: {"h1_pct": int|None, "h24_pct": int|None}} for every metric."""
    return compute_with_sources(state, now)[0]


def backfill(state, rows, now, source=None):
    """Seed the 10-minute bins from past readings, for a provider that has just started (or lost its state):
    rows is an iterable of (epoch, {metric: value}) in any order; readings from the current bin or later are
    left to update(). Existing bins are kept. `source` "h" marks the new bins as filled from Home Assistant's
    history (the display can say so). Returns the state dict."""
    st = state if isinstance(state, dict) else {}
    bins = st.setdefault("bins", {})
    cur = int(now // BIN_S)
    grouped = {}
    for t, vals in rows:
        if _num(t) is None:
            continue
        idx = int(t // BIN_S)
        if idx >= cur or now - t > KEEP_S:
            continue
        for m in METRICS:
            v = _num((vals or {}).get(m))
            if v is not None:
                grouped.setdefault((m, idx), []).append(v)
    for (m, idx), vs in grouped.items():
        entry = [statistics.median(vs), len(vs)] + ([source] if source else [])
        bins.setdefault(m, {}).setdefault(str(idx), entry)
    return st
