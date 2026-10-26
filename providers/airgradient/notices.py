# providers/airgradient/notices.py
# Event notices for the display's DATA line: facts about a sudden change in the indoor air, not advice.
#
# Pure standard library, no I/O. The provider keeps the notice state in its own state file and calls
# evaluate() after trend.update(): the "now" value is the median of the last NOW_S seconds of readings, the
# baseline is the median of the finished 10-minute bins from 40 to 10 minutes ago (both from trend.py's state),
# so a slow climb that takes longer than that to build never counts as a spike.
#
#   PM SPIKE   PM2.5 at least `pm_ratio` times its baseline and up at least `pm_min_rise` ug/m3
#   VOC SPIKE  VOC index up at least `voc_rise` over its baseline
#
# A notice holds until the reading is back under `hold_ratio` times the baseline it was measured against (that
# baseline is frozen when the notice starts, so a long event cannot raise its own bar), and for at most
# `cap_min` minutes. The text carries only what was measured: no guess at the cause.
import statistics

NOW_S = 180
BASE_NEAR_S = 600
BASE_FAR_S = 2400
MIN_NOW_SAMPLES = 3
MIN_BASE_BINS = 2
MIN_BIN_SAMPLES = 4
BIN_S = 600

DEFAULTS = dict(enabled=False, pm_ratio=3.0, pm_min_rise=10.0, voc_rise=150.0, voc_clear=75.0, hold_ratio=1.5, cap_min=60)
KINDS = (
    ("pm", "pm25_ugm3", "PM SPIKE // 2.5: {v:.0f}"),
    ("voc", "voc_index", "VOC SPIKE // {v:.0f}"),
)


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _now_value(trend_state, metric, now):
    recent = [x[1] for x in (trend_state.get("samples") or {}).get(metric, []) if 0 <= now - x[0] <= NOW_S]
    return statistics.median(recent) if len(recent) >= MIN_NOW_SAMPLES else None


def _baseline(trend_state, metric, now):
    """Median of the finished 10-minute bins that lie between 40 and 10 minutes ago, or None with fewer than two."""
    vals = []
    first, last = int((now - BASE_FAR_S) // BIN_S), int((now - BASE_NEAR_S) // BIN_S)
    bins = (trend_state.get("bins") or {}).get(metric, {})
    for idx in range(first, last):
        b = bins.get(str(idx))
        if b and b[1] >= MIN_BIN_SAMPLES:
            vals.append(b[0])
    return statistics.median(vals) if len(vals) >= MIN_BASE_BINS else None


def _fires(kind, now_v, base, c):
    if kind == "pm":
        base = max(base, 1.0)
        return now_v >= c["pm_ratio"] * base and now_v - base >= c["pm_min_rise"]
    return now_v - base >= c["voc_rise"]


def _cleared(kind, now_v, base, c):
    """Back to normal against the baseline the notice was measured against."""
    if kind == "pm":
        return now_v < c["hold_ratio"] * max(base, 1.0)
    return now_v - base < c["voc_clear"]


def evaluate(trend_state, state, now, cfg=None):
    """Returns (notices, state). `notices` is a list of {"type", "text", "since", "expires_at"} (epoch seconds), at most
    one per kind, PM first; `state` is the dict to keep for the next call."""
    c = {**DEFAULTS, **(cfg or {})}
    ts = trend_state if isinstance(trend_state, dict) else {}
    st = dict(state) if isinstance(state, dict) else {}
    out = []
    for kind, metric, fmt in KINDS:
        now_v = _now_value(ts, metric, now)
        held = st.get(kind)
        if held and (now - held["since"] > c["cap_min"] * 60 or (now_v is not None and _cleared(kind, now_v, held["base"], c))):
            st.pop(kind)
            held = None
        if not held and now_v is not None:
            base = _baseline(ts, metric, now)
            if base is not None and _fires(kind, now_v, base, c):
                held = st[kind] = {"since": now, "base": base}
        if held:
            v = now_v if now_v is not None else held["base"]
            out.append({"type": kind + "_spike", "text": fmt.format(v=v)[:29], "since": held["since"],
                        "expires_at": held["since"] + c["cap_min"] * 60})
    return out, st
