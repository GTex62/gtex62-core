# providers/air/air_backfill.py
# Rebuild what the air provider's `selected` readings were over the last day, so the outdoor trend columns work right after a
# start (or after the machine was off for days). Pure standard library, no I/O: fetch_air_extras.py does the two fetches.
#
# "Selected" is how fetch_air.sh builds it: OpenWeather's components as the base, overlaid per pollutant by AirNow's value from the
# nearest monitor that has a reading under `max_age` old (then that monitor's freshest reading). This module applies the same rules to
# AirNow's hourly rows (aq/data) and OpenWeather's history list, once per grid time, to give the same series the live loop would have
# recorded:
#   key names     PM2.5/PM25 -> pm2_5, PM10, OZONE/O3 -> o3, NO2, SO2, CO
#   value         RawConcentration when it is a number >= 0 (AirNow marks "not yet available" as -999), else Value
#   units         ug/m3 as is, mg/m3 x 1000, ppb x 1.96 (ozone) / 1.88 (NO2) / 2.62 (SO2), ppm x 1145 (CO)
#   nearest       squared distance with longitude scaled by cos(latitude); rows without coordinates rank last
import math
from datetime import datetime, timezone

KEYS = {"PM2.5": "pm2_5", "PM2_5": "pm2_5", "PM25": "pm2_5", "PM10": "pm10", "OZONE": "o3", "O3": "o3",
        "NO2": "no2", "NO": "no2", "SO2": "so2", "SO": "so2", "CO": "co"}
METRICS = ("pm2_5", "o3", "pm10", "no2", "so2", "co", "nh3")


def _num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _to_ugm3(key, unit, value):
    u = str(unit or "").upper()
    if u in ("UG/M3", "UG/M^3", "UG/M³"):
        return value
    if u in ("MG/M3", "MG/M^3"):
        return value * 1000
    if u == "PPB" and key == "o3":
        return value * 1.96
    if u == "PPB" and key == "no2":
        return value * 1.88
    if u == "PPB" and key == "so2":
        return value * 2.62
    if u == "PPM" and key == "co":
        return value * 1145
    return None


def _epoch(s):
    """AirNow's UTC stamp "YYYY-MM-DDTHH:MM" (or ...THH) as epoch seconds, or None."""
    if isinstance(s, (int, float)) and not isinstance(s, bool):
        return float(s)
    s = str(s or "")
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%dT%H"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    return None


def airnow_rows(raw, lat, lon):
    """[(key, ug/m3 value, epoch, squared distance)] for every usable row of an aq/data reply."""
    out = []
    for r in raw if isinstance(raw, list) else []:
        if not isinstance(r, dict):
            continue
        key = KEYS.get(str(r.get("Parameter", "")).upper())
        raw_c = _num(r.get("RawConcentration"))
        value = raw_c if raw_c is not None and raw_c >= 0 else _num(r.get("Value"))
        ts = _epoch(r.get("UTC"))
        if key is None or value is None or ts is None:
            continue
        value = _to_ugm3(key, r.get("Unit"), value)
        if value is None or value < 0:
            continue
        slat, slon = _num(r.get("Latitude")), _num(r.get("Longitude"))
        if slat is None or slon is None:
            d2 = 1e9
        else:
            dy = slat - lat
            dx = (slon - lon) * math.cos(math.radians(lat))
            d2 = dy * dy + dx * dx
        out.append((key, value, ts, d2))
    return out


def airnow_at(rows, t, max_age):
    """{key: value} AirNow would have supplied at time t: per pollutant the nearest monitor with a reading under max_age old, then its
    freshest reading."""
    best = {}
    for key, value, ts, d2 in rows:
        age = t - ts
        if age < 0 or age > max_age:
            continue
        cand = (d2, age, value)
        if key not in best or cand[:2] < best[key][:2]:
            best[key] = cand
    return {k: v[2] for k, v in best.items()}


def owm_at(history, t):
    """OpenWeather's components at time t: the newest history entry at or before t (entries are hourly)."""
    best = None
    for e in history if isinstance(history, list) else []:
        if not isinstance(e, dict):
            continue
        dt = _num(e.get("dt"))
        if dt is not None and dt <= t and (best is None or dt > best[0]) and isinstance(e.get("components"), dict):
            best = (dt, e["components"])
    return {k: _num(v) for k, v in best[1].items() if _num(v) is not None} if best else {}


def series(anw_raw, owm_list, lat, lon, now, max_age=3600, hours=27, step=900):
    """[(t, {metric: value})] on a grid from `hours` ago up to one step before `now`: OpenWeather as the base, AirNow over it."""
    rows = airnow_rows(anw_raw, lat, lon)
    out = []
    t = now - hours * 3600
    while t < now - 60:
        sel = owm_at(owm_list, t)
        sel.update(airnow_at(rows, t, max_age))
        vals = {m: sel[m] for m in METRICS if sel.get(m) is not None}
        if vals:
            out.append((t, vals))
        t += step
    return out
