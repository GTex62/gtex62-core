# Ventilation Advisor (Open / Close Windows)

Engine-side classification that compares indoor AirGradient readings against outdoor
air and weather data and produces a single verdict: do conditions favor opening the
windows, keeping them closed, or does it not matter. It is the "Ventilation Advisor" section of
`airgradient-provider-design.md`, which owns the `status.json` schema and the display; this
document owns the rules, thresholds and reference code.

OSA displays the verdict and raises the alert. It does not compute it.

Revision 4 (2026-10-07): outdoor PM now has two source tiers (AirNow station readings drive every
PM rule; OpenWeather's modelled PM drives only the hard-close); pollen is a soft drawback that can
only weigh against an existing need; the indoor-humidity rule uses outdoor dew point when it is
available; rules return a structured result with the alert text; everything is time-based
(epoch seconds) instead of sample-based; visible alerts are limited to need-based advice, hazards
and indoor humidity. Revision 3 added the humidity trip, hysteresis, dwell and the sustain filter,
and demoted VOC to an annotation. Checked against seven days of history (Oct 1 to Oct 7, 9,840
one-minute samples); thresholds are still defaults to be tuned (see Open Items).

---

## Inputs

| Side | Fields | Source |
| --- | --- | --- |
| Indoor | `co2_ppm`, `voc_index`, `pm.pm25_ugm3`, `temp_f`, `humidity_pct` | `shared/airgradient/<profile>/status.json` |
| Indoor (derived) | `dp_rise_30`: indoor dew point now minus dew point at exactly 30 minutes ago (F), interpolated | engine keeps a 30-minute dew point history |
| Outdoor air | `airnow.aqi` (the overall AQI: the highest pollutant sub-index, as the air provider has computed it since 2026-10-08); `selected.pm2_5` and `.pm10` (AirNow where present, else OpenWeather); `openweather.components.pm2_5` and `.pm10` | `shared/air/<air_profile>/current.json` |
| Outdoor weather | `temp_f`, `humidity_pct` | `shared/weather/<weather_profile>/current.json` |
| Outdoor weather hazards | thunder and rain now: OpenWeather `wx_code` (200s thunder; 300s and 500s drizzle and rain) while `wx_fresh`, or present weather in the METAR (TS, RA, DZ, SH, VCTS; a report under 90 minutes old); expected: present weather in the TAF groups (FM, BECMG, TEMPO, PROB) that start within the look-ahead (`[advisor] storm_lookahead_min`, default 180) | `shared/weather/<weather_profile>/current.json`, `shared/aviation/<aviation_profile>/current.json` (`metar_raw`, `taf_raw`; the TAF is ignored if that cache is over 2 hours old) |
| Wind direction | OpenWeather `wind_deg` while `wx_fresh`, else the METAR wind (variable or calm = unknown); for forecast rain, the wind of the TAF group that carries the rain | same files |

The provider turns these into `ts_min` and `rain_min` (minutes until thunder or rain at the site: 0 means under way, absent means
none expected) and `wind_deg` / `rain_wind_deg`; the advisor itself stays pure. `[advisor] window_facing_deg` (the compass direction
the windows face; 180 for south) switches the rain rules on, and `wind_side_deg` (default 90) is the half-angle that counts as
"toward the windows". The TAF and METAR describe the airport, not the house; OpenWeather is closer to the site, so it is used first for
rain now and for the wind direction.
| Pollen (optional) | `tree`, `grass`, `weed`, `mold` (0 to 100 seasonal index) | `pollen_mem_v2.csv`, day-of-year lookup, path from the profile TOML (see below) |

**Outdoor PM source.** `pm_source` is `airnow` when `airnow.values.pm2_5` is present and `owm`
otherwise (`selected.*` falls back to OpenWeather's modelled value). AirNow readings come from
monitoring stations and, in the site owner's experience in this region, are the better source;
OpenWeather's number is a model. Rules therefore use them differently:

- Hard-close (rule 1) trips on **either** source: the `selected` value or OpenWeather's own
  component, whichever is higher (`owm_pm25`/`owm_pm10` in the reference code). An AirNow reading
  can be up to 2 hours old (`max_age_sec = 7200`) while OpenWeather's model is current, and a fast
  event such as smoke must not be masked by an older, calmer station reading. Recency does not make
  the model the better estimate of ordinary conditions, which is why it never drives the soft rules.
- The soft PM comparisons (indoor PM need relative to outdoor, outdoor PM drawback) run only with
  `pm_source = airnow`. With OpenWeather alone they are skipped and the indoor PM need falls back to
  its absolute trigger.
- On 2026-10-07 at 21:57 CDT OpenWeather showed PM2.5 13.3 while the AirNow stations in the search
  radius showed 6.7 to 9.7 for the latest hour (6.4 to 10.9 over the previous five); applying the soft rules to the OpenWeather number would have called
  for `CLOSE` with clean indoor air.

**Freshness.** Each outdoor input has its own flag so a stale one only switches off the rules that
need it:

- `air_fresh`: `generated_at` of the air cache is under 2 hours old (the provider is alive).
  `provider_updated_at` is not used: it is AirNow's hourly observation timestamp, which routinely
  lags by an hour or more while OpenWeather values are current.
- `wx_fresh`: `provider_updated_at` of the weather cache is under 30 minutes old (its TTL is 5
  minutes).
- Not `air_fresh`: hard-close and the soft PM rules are skipped. Not `wx_fresh`: the outdoor
  temperature, free-cooling and dew point rules are skipped. Indoor rules always run.

**Pollen file.** The profile TOML key `pollen_csv` defaults to
`$GTEX62_SHARED_ASSETS/data/pollen/pollen_mem_v2.csv` (`~/.config/conky/gtex62-shared-assets` when
the variable is unset), the same default `env.lua` uses. A missing file turns pollen off, silently
apart from one log line. The advisor must read v2 (v1 and v2 disagree on mold).

HVAC state (`hvac_action`, setpoint) is not an input: the engine has no Home Assistant access. See
Open Items.

---

## Verdicts

| Verdict | Meaning | Reason text starts | Shows an alert |
| --- | --- | --- | --- |
| `OPEN` | Indoor air needs ventilating and nothing outside argues against it | "Open windows: " | yes |
| `BRIEF` | Indoor need exists but outdoor conditions, pollen or humidity are a drawback | "Air out briefly (5-10 min): " | yes |
| `CLOSE`, class `hazard` | Outdoor air is hazardous | "Close windows: outdoor air quality is poor" | yes |
| `CLOSE`, class `humidity` | Indoor humidity is high and outdoor air is not clearly drier | "Close windows: humidity 73%" | yes |
| `CLOSE`, class `advisory` | Only soft drawbacks (outdoor too hot, cold, humid, or dusty by AirNow) and no need | "Keep windows closed: " | **no** (logged only) |
| `NEUTRAL` | Either is fine | "Fine either way" | no |

The verdict means "conditions favor", not "windows are currently open". There is no window
sensor, so the advisor cannot know the actual window state. Advisory `CLOSE` is kept in the verdict
and the shadow log, but it does not raise the banner: a 95 F afternoon with good indoor air is not
worth telling anyone about.

---

## Rules (evaluated in this order)

1. **Hard close**: outdoor AQI >= 101, outdoor PM2.5 >= 35.5 ug/m3, or outdoor PM10 >= 155, from
   either PM source. Verdict is `CLOSE` (class `hazard`) regardless of indoor readings or pollen. If
   indoor CO2 is also >= 1000, the message adds "use an air purifier or a very short airing".
   Skipped unless `air_fresh`.
1b. **Weather hard close** (the user's site rules; thunder needs no configuration, rain needs the window
   direction):
   - **Thunderstorm** now (METAR or OpenWeather) or in the TAF within the look-ahead (default 180 minutes):
     `CLOSE` class `hazard`, `CLOSE WIN // STORM`. A storm front can swing the wind violently, so no wind
     direction is consulted.
   - **Rain** (rain, drizzle or showers) **now** with the wind coming from within 90 degrees of the direction the
     windows face (`window_facing_deg`; a south-facing office is 180, so any wind from the southern half):
     `CLOSE` class `hazard`, `CLOSE WIN // RAIN`. Variable or unknown wind counts as the window side. Rain now
     with the wind from the other half is a note only ("raining: a wind shift could blow rain in"): airing out
     is still fine, but watch the radar.
   - **Rain forecast** (TAF) within the look-ahead with the forecast wind toward the windows: a soft drawback
     ("rain expected within N min with the wind toward the windows"), so a need is `BRIEF` instead of `OPEN`;
     otherwise a note ("rain expected within N min").
   - Without `window_facing_deg` rain is only ever a note; thunder still closes.
2. **Indoor humidity trip** (indoor data only):
   - Enter when indoor RH >= 70%, **or** indoor RH >= 66% with the dew point up 4 F or more in 30
     minutes.
   - Release when RH < 66% **and** the 30-minute dew point rise is below 2 F.
   - If outdoor air is clearly drier (outdoor dew point at least 2 F below indoor, `wx_fresh`), the
     moisture is better vented than trapped: no verdict yet, rule 3 counts it as a need
     ("indoor RH 73% and drier outside"). This is the morning-shower case.
   - Otherwise (outdoor not drier, or no outdoor weather): `CLOSE` class `humidity`. If need is
     severe (CO2 >= 1500 or VOC >= 250) it is `BRIEF` instead.
3. **Indoor need** (any one triggers):
   - CO2 >= 1000 ppm
   - VOC index >= 250 (severe; see *VOC* below)
   - indoor PM2.5 >= 9 ug/m3 **and**, when `pm_source = airnow`, at least 3 ug/m3 above outdoor PM2.5
   - indoor RH >= 60% (or the humidity trip is active) and outdoor dew point at least 2 F lower than
     indoor dew point
   - indoor > 78 F and outdoor at least 5 F cooler, inside the 55 to 85 F band (free cooling)
4. **Outdoor drawbacks** (soft, any one counts):
   - outdoor temperature above 85 F or below 55 F
   - outdoor dew point at least 2 F above indoor dew point while indoor RH >= 50%
   - outdoor PM2.5 above 9 ug/m3 and at least 3 ug/m3 above indoor PM2.5 (`pm_source = airnow` only)
   - pollen: tree or grass at or above `pollen_threshold` (default 80), **only when a need exists**
5. **Combine**: need and no drawback is `OPEN`. Need with a drawback is `BRIEF`, except that severe
   need (CO2 >= 1500 or VOC >= 250) is `OPEN` regardless. No need but a drawback is `CLOSE` (class
   `advisory`). Neither is `NEUTRAL`.
6. **Pollen annotation**: the message always appends any category at or above 50, e.g.
   `| pollen: mold 91, weed 65`. Mold and weed are annotations only by default.

Severity is `severe` when CO2 >= 1500 or VOC >= 250, else `normal`. It exists so that a growing
problem under an unchanged verdict can start a new alert (see Alert behavior).

**VOC.** The AirGradient VOC index is relative to a baseline the sensor learns over about
120 hours, so an absolute threshold is a poor trigger. Over the week the index sat at 150 or
above for 4,060 of 9,840 minutes (41%); the daily median was 160 to 191 on Oct 1 to 3. It also
climbs smoothly for hours with CO2 and PM flat, which looks like the sensor's own scaling and
not a real source. A VOC of 150 to 249 is therefore shown as an annotation only. 250 or higher
still counts as need: that was 455 minutes (4.6%) in six runs, two of them long (Oct 1
21:16 to Oct 2 01:58, peak 475; Oct 4 20:35 to 23:12, peak 310), and the sustain filter drops the
shortest. If those match a real activity the advice to ventilate is right; if not, they are the
sensor's scaling and this line may need to rise. VOC has no release hysteresis in v1 (a release
near 200 would change the replay, so it waits for shadow data); only the dwell limits flapping.

**Why pollen is soft.** The values come from a static seasonal curve, not a measurement, and the
curve cannot see today's rain or wind. Live pollen sources were evaluated and set aside: they cost
money, local values are not free, and they are not very accurate; a local sensor means expense and
setup. Hazards outweigh pollen, and so does a severe need; pollen only tips a marginal case from
`OPEN` toward `BRIEF`. It never raises an alert by itself (nothing is weighed against a need that
does not exist). Tree and grass are the defaults because mold is at or above 80 for about 130 days
a year in `pollen_mem_v2.csv` (mid-June to early November) and would otherwise weigh against the
windows for a third of the year. `pollen_categories` in the profile TOML can change the set.

Compare **dew point**, not relative humidity: RH depends on temperature, so 70% RH outside
at 60 F is drier air than 55% RH inside at 73 F. The same applies to the humidity trip's second
clause: it watches dew point rise (moisture added), because RH alone also moves when the
temperature does. Observed example: on 2026-10-07 RH went from 63% to 73% between 06:15 and
06:48 while the temperature rose only 1 F and the dew point rose from 57.0 F to 62.0 F.

The absolute floors (9 ug/m3 PM2.5, 1000 ppm CO2, 55 to 85 F, 70% RH) are what keep the advisor
from nagging when everything is already good: outdoor PM2.5 of 5 versus indoor 2 is not worth
an alert. The numbers follow common guidelines (the EPA "Good" ceiling for PM2.5, the usual
1000 ppm CO2 comfort line) and are meant to be tuned. Every number above is a key in the profile
TOML, so tuning during the shadow week needs no code change; the reference code's `DEFAULTS`
dictionary lists them.

---

## Alert behavior

- **Alert on verdict change only**, not on every poll. A change of verdict, severity going from
  `normal` to `severe` under the same verdict, or a `hazard` with a different alert text (outdoor air to
  thunderstorm, say; an advisory `CLOSE` that becomes a hazard) starts a new alert.
- **Hysteresis** so values near a threshold do not flap: enter `OPEN` for CO2 at >= 1000
  but leave it below 800; enter on indoor PM2.5 >= 9 but leave below 6; humidity trip as in
  rule 2.
- **Minimum dwell** of 600 seconds before the published verdict can change again. A hard-close
  therefore can lag a hazard by up to 10 minutes after a previous change.
- **Sustain filter**: CO2, PM2.5 and VOC use the minimum over the last 180 seconds (the window
  `(t - 180 s, t]`; at one-minute samples that is exactly 3 samples). The window must hold at least
  two samples spanning 60 seconds or more; until then the three values are unavailable and the need
  rules are skipped (the humidity trip and the hard-close still run). A single-minute spike cannot
  trigger an alert (a one-minute CO2 reading of 1,004 on Oct 2 would otherwise have).
- **Dew point rise**: indoor dew point now minus the value at exactly `t - 1800 s`, linearly
  interpolated between the two surrounding samples, which must be no more than 120 seconds apart.
  With no bracket (first 30 minutes, or after an outage) the rise is 0. A tolerance wider than
  this changes results: at 08:29 on 2026-10-07 the rise is 3.93 F against the 4 F trigger, and a
  lookback that picks a nearby sample instead of interpolating fires a minute early.
- **Gaps**: if the time between two good readings exceeds 600 seconds, the sustain window and the
  dew point history are cleared rather than bridged. Latches and the dwell clock are kept.
- **Time**: all arithmetic is epoch seconds. Local datetimes break at the DST change (2026-11-01).
- **Disabled/degraded**: the advisor is not stepped. The last verdict is held and the alert cap
  keeps running; OSA shows `AG STALE` once the reading is 3 minutes old.
- **Partial readings**: the provider carries individual missing fields forward (see the provider
  document); a field with no value inside its maximum age reaches the advisor as null, and every
  rule that needs it is skipped.
- **Alert visibility**: only `OPEN`, `BRIEF`, `CLOSE`/`hazard` and `CLOSE`/`humidity` are visible,
  for at most 3600 seconds from the change or escalation. On the 281-minute VOC episode of Oct 1 the
  alert would have been visible for the first 60 minutes only.

### Alert line text (29 characters or fewer)

Built in the same pass as the verdict, from structured needs, not by parsing the reason string.
When several needs are active the first of this list names the alert: CO2, VOC, PM2.5, humidity,
free cooling.

| Condition | Text |
| --- | --- |
| `OPEN`, CO2 | `OPEN WIN // CO2 1150 PPM` |
| `OPEN`, VOC | `OPEN WIN // VOC 263` |
| `OPEN`, indoor PM | `OPEN WIN // PM2.5 14.6` |
| `OPEN`, humid and outdoor drier | `OPEN WIN // HUMID, DRIER OUT` |
| `OPEN`, free cooling | `OPEN WIN // COOLER OUTSIDE` |
| `BRIEF` | `BRIEF OPEN // ` + the same short need (`DRIER OUT` for humidity) |
| `BRIEF`, humidity trip with severe need | `BRIEF OPEN // CO2 1700 PPM` or `BRIEF OPEN // VOC 270` |
| `CLOSE`, hazard | `CLOSE WIN // OUTDOOR AIR` |
| `CLOSE`, humidity | `CLOSE WIN // HUMID INSIDE` |
| `CLOSE`, hazard, thunder | `CLOSE WIN // STORM` |
| `CLOSE`, hazard, rain toward the windows | `CLOSE WIN // RAIN` |
| `CLOSE`, advisory, `NEUTRAL` | none |

The earlier `HUMID OUTSIDE` text is gone: outdoor air being more humid is now only an advisory
drawback, and a humidity trip with wetter outdoor air reads `HUMID INSIDE`, which is true either way.

---

## Output

The advisor's result is written under `ventilation` in `status.json`; the field list is in
`airgradient-provider-design.md`. The reference code returns a dictionary with `verdict`,
`severity`, `reason`, `cls` (`hazard`, `humidity`, `need`, `advisory`, `none`), `needs` and `blocks`
(code lists), `notes` (annotations) and `alert_text`; the stateful wrapper adds `since`, and its
`alert(t)` method returns `visible`, `text` and `expires_at`.

---

## Reference implementation (tested)

This is the code the acceptance test and the synthetic cases below were run against. It is the
specification: the production module may be structured differently but must give the same results.
Inputs `out` and `pollen` are optional; `None` outdoor data means indoor-only.

```python
import math

DEFAULTS = dict(
    dwell_s=600, sustain_s=180, warm_s=60, reset_gap_s=600,
    rise_lag_s=1800, rise_gap_s=120, alert_cap_s=3600,
    hard_aqi=101, hard_pm25=35.5, hard_pm10=155,
    co2_enter=1000, co2_leave=800, co2_severe=1500,
    voc_need=250, voc_note=150,
    pm_enter=9, pm_leave=6, pm_margin=3,
    rh_enter=70, rh_floor=66, rise_enter=4, rise_leave=2,
    rh_need=60, rh_block=50, dp_margin=2,
    cool_indoor=78, cool_delta=5, out_hot=85, out_cold=55,
    pollen_note=50, pollen_threshold=80, pollen_categories=('tree', 'grass'),
    window_facing_deg=None, wind_side_deg=90,
)

def num(x):
    """JSON null, strings, bools and NaN all become None."""
    ok = isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
    return float(x) if ok else None

def dewpoint_f(temp_f, rh):
    temp_f, rh = num(temp_f), num(rh)
    if temp_f is None or rh is None or rh <= 0:
        return None
    c = (temp_f - 32) / 1.8
    a, b = 17.62, 243.12
    g = math.log(rh / 100.0) + a * c / (b + c)
    return (b * g / (a - g)) * 1.8 + 32

def angle_diff(a, b):
    d = abs(a - b) % 360
    return min(d, 360 - d)

def wind_on_windows(wind_deg, c=DEFAULTS):
    """Would rain be blown in? True when the wind comes from within wind_side_deg of the direction the
    windows face; unknown or variable wind counts as yes (the cautious answer). None when the profile
    does not say which way the windows face."""
    facing = num(c['window_facing_deg'])
    if facing is None:
        return None
    d = num(wind_deg)
    return True if d is None else angle_diff(d, facing) <= c['wind_side_deg']

def humid_trip(rh, rise, latched, c=DEFAULTS):
    """Entry: RH >= 70, or RH >= 66 with dew point up >= 4F in 30 min.
    Release (hysteresis): RH < 66 and dew point rise < 2F."""
    if rh >= c['rh_enter'] or (rh >= c['rh_floor'] and rise >= c['rise_enter']):
        return True
    return latched and (rh >= c['rh_floor'] or rise >= c['rise_leave'])

def advise(ind, out=None, latched=frozenset(), pollen=None, cfg=None):
    """Pure rule evaluation. `ind` holds sustained co2/pm25/voc (None while the
    sustain window is not yet warm), instantaneous temp_f/rh, and dp_rise_30.
    `out` (all keys optional): ts_min and rain_min (minutes until thunder / rain at the site, 0 = now,
    absent = none expected), wind_deg and rain_wind_deg (wind now / in the forecast rain period), aqi, pm25, pm10 (the air cache's `selected` values), pm_source
    ('airnow'|'owm'), owm_pm25, owm_pm10 (OpenWeather's own components), air_fresh, temp_f, rh,
    wx_fresh. Returns a structured dict."""
    c = {**DEFAULTS, **(cfg or {})}
    o = out or {}
    co2, voc, pm = num(ind.get('co2')), num(ind.get('voc')), num(ind.get('pm25'))
    rh, tin = num(ind.get('rh')), num(ind.get('temp_f'))
    rise = num(ind.get('dp_rise_30')) or 0.0

    air_ok = bool(o.get('air_fresh'))
    aqi, o25, o10 = num(o.get('aqi')), num(o.get('pm25')), num(o.get('pm10'))
    # The hazard rule trips on either source: an hours-old station reading must not mask a
    # current modelled spike (smoke, dust).
    hz25 = max((x for x in (o25, num(o.get('owm_pm25'))) if x is not None), default=None)
    hz10 = max((x for x in (o10, num(o.get('owm_pm10'))) if x is not None), default=None)
    # Soft PM comparisons need a station reading; OpenWeather's modelled PM only feeds hard-close.
    soft_pm = air_ok and o.get('pm_source') == 'airnow' and o25 is not None
    otemp, orh = num(o.get('temp_f')), num(o.get('rh'))
    wx_ok = bool(o.get('wx_fresh')) and otemp is not None
    dp_in = dewpoint_f(tin, rh)
    dp_out = dewpoint_f(otemp, orh) if wx_ok else None
    drier = dp_in is not None and dp_out is not None and dp_out <= dp_in - c['dp_margin']
    wetter = dp_in is not None and dp_out is not None and dp_out >= dp_in + c['dp_margin']

    def hi(x, t):
        return x is not None and x >= t

    severe = hi(co2, c['co2_severe']) or hi(voc, c['voc_need'])
    sev = 'severe' if severe else 'normal'

    def res(verdict, reason, cls, needs=(), blocks=(), notes=(), alert=''):
        return dict(verdict=verdict, severity=sev, reason=reason, cls=cls,
                    needs=[n[0] for n in needs], blocks=[b[0] for b in blocks],
                    notes=list(notes), alert_text=alert)

    # 1. hard close: outdoor air hazardous (never overridden)
    if air_ok and (hi(aqi, c['hard_aqi']) or hi(hz25, c['hard_pm25']) or hi(hz10, c['hard_pm10'])):
        why = 'Close windows: outdoor air quality is poor'
        if hi(co2, c['co2_enter']):
            why += ' (CO2 is high; use an air purifier or a very short airing)'
        return res('CLOSE', why, 'hazard', alert='CLOSE WIN // OUTDOOR AIR')

    # 1b. hard close: thunder now or expected (the wind can shift violently), or rain now with the wind
    # blowing onto the windows. Rain with the wind away from them is only a note (see 5).
    ts, rain = num(o.get('ts_min')), num(o.get('rain_min'))
    if ts is not None:
        when = 'now' if ts <= 0 else f"expected within {ts:.0f} min"
        return res('CLOSE', 'Close windows: thunderstorm ' + when, 'hazard', alert='CLOSE WIN // STORM')
    if rain is not None and rain <= 0 and wind_on_windows(o.get('wind_deg'), c):
        return res('CLOSE', 'Close windows: raining with the wind toward the windows', 'hazard',
                   alert='CLOSE WIN // RAIN')

    # 2. indoor humidity trip (needs no outdoor data)
    tripped = rh is not None and humid_trip(rh, rise, 'humid' in latched, c)
    if tripped and not drier:
        why = f"humidity {rh:.0f}%" + (f" (dew point {rise:+.0f}F in 30 min)" if rise >= 2 else '')
        if severe:
            first = f"CO2 {co2:.0f} PPM" if hi(co2, c['co2_severe']) else f"VOC {voc:.0f}"
            return res('BRIEF', 'Air out briefly (5-10 min): CO2/VOC high; but ' + why, 'need',
                       alert='BRIEF OPEN // ' + first)
        return res('CLOSE', 'Close windows: ' + why, 'humidity', alert='CLOSE WIN // HUMID INSIDE')

    # 3. indoor need: (code, long text, short text for the alert line)
    needs = []
    if hi(co2, c['co2_enter']) or ('co2' in latched and hi(co2, c['co2_leave'])):
        needs.append(('co2', f"CO2 {co2:.0f} ppm", f"CO2 {co2:.0f} PPM"))
    if hi(voc, c['voc_need']):
        needs.append(('voc', f"VOC index {voc:.0f}", f"VOC {voc:.0f}"))
    if (hi(pm, c['pm_enter']) or ('pm' in latched and hi(pm, c['pm_leave']))) \
            and (not soft_pm or pm >= o25 + c['pm_margin']):
        needs.append(('pm', f"indoor PM2.5 {pm:.1f}", f"PM2.5 {pm:.1f}"))
    # humid indoors (tripped, or RH >= 60) and outdoor air clearly drier: ventilate.
    # A tripped humidity with drier outdoor air lands here instead of rule 2.
    if drier and rh is not None and (tripped or rh >= c['rh_need']):
        needs.append(('humid', f"indoor RH {rh:.0f}% and drier outside", 'DRIER OUT'))

    # 4. outdoor drawbacks (soft)
    blocks = []
    if wx_ok:
        if wetter and rh is not None and rh >= c['rh_block']:
            blocks.append(('humid_out', 'outdoor air is more humid'))
        if otemp > c['out_hot'] or otemp < c['out_cold']:
            blocks.append(('temp', f"outdoor {otemp:.0f}F"))
        elif tin is not None and tin > c['cool_indoor'] and otemp <= tin - c['cool_delta']:
            needs.append(('cool', 'free cooling available', 'COOLER OUTSIDE'))
    if soft_pm and o25 > c['pm_enter'] and pm is not None and o25 >= pm + c['pm_margin']:
        blocks.append(('pm_out', f"outdoor PM2.5 {o25:.0f}"))
    if rain is not None and rain > 0 and wind_on_windows(o.get('rain_wind_deg', o.get('wind_deg')), c):
        blocks.append(('rain', f"rain expected within {rain:.0f} min with the wind toward the windows"))

    # 5. pollen: annotation always; a soft drawback only when there is a need to weigh it against
    pol = pollen or {}
    notes = []
    if rain is not None and not any(b[0] == 'rain' for b in blocks):
        notes.append('raining: a wind shift could blow rain in' if rain <= 0 else f"rain expected within {rain:.0f} min")
    if hi(voc, c['voc_note']) and voc < c['voc_need']:
        notes.append(f"VOC index {voc:.0f} (relative, informational)")
    high = {k: num(pol.get(k)) for k in ('tree', 'grass', 'weed', 'mold')}
    shown = sorted(((k, v) for k, v in high.items() if v is not None and v >= c['pollen_note']),
                   key=lambda kv: -kv[1])
    if shown:
        notes.append('pollen: ' + ', '.join(f"{k} {v:.0f}" for k, v in shown))
    pol_hi = [(k, high[k]) for k in c['pollen_categories'] if high.get(k) is not None
              and high[k] >= c['pollen_threshold']]
    if needs and pol_hi:
        blocks.append(('pollen', 'pollen is high (' + ', '.join(f"{k} {v:.0f}" for k, v in pol_hi) + ')'))

    tail = (' | ' + '; '.join(notes)) if notes else ''
    need_txt = ', '.join(n[1] for n in needs)
    block_txt = ', '.join(b[1] for b in blocks)

    def short(verdict):
        code, _, s = needs[0]
        return 'HUMID, DRIER OUT' if (code == 'humid' and verdict == 'OPEN') else s

    # 6. combine
    if needs and (not blocks or severe):
        return res('OPEN', 'Open windows: ' + need_txt + tail, 'need', needs, blocks, notes,
                   'OPEN WIN // ' + short('OPEN'))
    if needs:
        return res('BRIEF', f'Air out briefly (5-10 min): {need_txt}; but {block_txt}' + tail, 'need',
                   needs, blocks, notes, 'BRIEF OPEN // ' + short('BRIEF'))
    if blocks:
        return res('CLOSE', 'Keep windows closed: ' + block_txt + tail, 'advisory', needs, blocks, notes)
    return res('NEUTRAL', 'Fine either way' + tail, 'none', notes=notes)


class Advisor:
    """Stateful wrapper: sustain window, hysteresis latches, minimum dwell, alert cap.
    All times are epoch seconds (never local datetimes: DST)."""

    def __init__(self, cfg=None):
        self.c = {**DEFAULTS, **(cfg or {})}
        self.latched = set()
        self.verdict, self.severity, self.reason = 'NEUTRAL', 'normal', 'Fine either way'
        self.cls, self.alert_text, self.notes = 'none', '', []
        self.since = self.alert_since = self.last_t = None
        self.samples, self.dps = [], []          # [t, co2, pm25, voc] / [t, dew_point]

    def to_state(self):
        return {k: (sorted(v) if isinstance(v, set) else v) for k, v in vars(self).items() if k != 'c'}

    @classmethod
    def from_state(cls, st, cfg=None):
        a = cls(cfg)
        a.__dict__.update(st)
        a.latched = set(st.get('latched', []))
        return a

    def _rise(self, t):
        """Dew point now minus dew point at exactly t-30min, interpolated; None if no bracket."""
        target = t - self.c['rise_lag_s']
        a = max((x for x in self.dps if x[0] <= target), key=lambda x: x[0], default=None)
        b = min((x for x in self.dps if x[0] >= target), key=lambda x: x[0], default=None)
        if a is None or b is None or b[0] - a[0] > self.c['rise_gap_s']:
            return None
        then = a[1] if b[0] == a[0] else a[1] + (b[1] - a[1]) * (target - a[0]) / (b[0] - a[0])
        return self.dps[-1][1] - then

    def step(self, t, ind, out=None, pollen=None):
        """Feed one good reading. Returns 'change' (published verdict changed: alert fires),
        'escalate' (same verdict, severity normal -> severe), or None."""
        c = self.c
        if self.last_t is not None:
            if t <= self.last_t:
                return None                                   # duplicate or clock stepped back
            if t - self.last_t > c['reset_gap_s']:
                self.samples, self.dps = [], []               # outage: do not bridge it
        self.last_t = t

        dp = dewpoint_f(ind.get('temp_f'), ind.get('rh'))
        horizon = c['rise_lag_s'] + c['rise_gap_s']
        if dp is not None:
            self.dps = [x for x in self.dps if t - x[0] <= horizon] + [[t, dp]]
        self.samples = [s for s in self.samples if t - s[0] < c['sustain_s']] \
            + [[t, num(ind.get('co2')), num(ind.get('pm25')), num(ind.get('voc'))]]

        warm = len(self.samples) >= 2 and t - self.samples[0][0] >= c['warm_s']
        def low(i):
            vals = [s[i] for s in self.samples if s[i] is not None]
            return min(vals) if warm and vals else None
        co2, pm, voc = low(1), low(2), low(3)

        rise = (self._rise(t) if dp is not None else None) or 0.0
        rh = num(ind.get('rh'))
        for name, v, enter, leave in (('co2', co2, c['co2_enter'], c['co2_leave']),
                                      ('pm', pm, c['pm_enter'], c['pm_leave'])):
            if v is None:
                continue
            if v >= enter:
                self.latched.add(name)
            elif v < leave:
                self.latched.discard(name)
        if rh is not None:
            (self.latched.add if humid_trip(rh, rise, 'humid' in self.latched, c)
             else self.latched.discard)('humid')

        r = advise(dict(co2=co2, pm25=pm, voc=voc, temp_f=ind.get('temp_f'), rh=rh, dp_rise_30=rise),
                   out, frozenset(self.latched), pollen, c)
        if r['verdict'] == self.verdict:
            escalated = (self.severity == 'normal' and r['severity'] == 'severe' and r['verdict'] != 'NEUTRAL') \
                or (r['cls'] == 'hazard' and r['alert_text'] != self.alert_text)
            self.reason, self.severity, self.cls, self.alert_text = \
                r['reason'], r['severity'], r['cls'], r['alert_text']
            self.notes = r['notes']
            if escalated:
                self.alert_since = t
                return 'escalate'
            return None
        if self.since is None or t - self.since >= c['dwell_s']:
            self.verdict, self.severity, self.reason = r['verdict'], r['severity'], r['reason']
            self.cls, self.alert_text, self.notes = r['cls'], r['alert_text'], r['notes']
            self.since = self.alert_since = t
            return 'change'
        return None

    def alert(self, t):
        """What OSA should show. Visible for need-based verdicts, hazard CLOSE and humidity CLOSE,
        for at most alert_cap_s after the verdict changed or severity escalated."""
        shown = self.verdict in ('OPEN', 'BRIEF') or (self.verdict == 'CLOSE' and self.cls in ('hazard', 'humidity'))
        if not (shown and self.alert_text and self.alert_since is not None):
            return dict(visible=False, text='', expires_at=None)
        exp = self.alert_since + self.c['alert_cap_s']
        return dict(visible=t < exp, text=self.alert_text if t < exp else '', expires_at=exp)
```

---

## Acceptance test

**Fixtures:** `tests/airgradient/fixtures/week_1min.csv` (9,840 one-minute samples, 2026-10-01
00:00 to 10-07 19:59 local, columns include `utc_time`) and
`tests/airgradient/fixtures/expected_verdict_changes.csv`.

**Replay:** step the data forward at one-minute intervals, indoor-only (`out=None`), feeding
`co2_ppm`, `pm25_ugm3`, `voc_index`, `temp_f`, `humidity_pct` and time from `utc_time` as epoch
seconds. The published verdict changes (`step` returns `'change'`) must equal
`expected_verdict_changes.csv` in time, verdict **and reason text**: 18 changes, 469 minutes `OPEN`,
294 `CLOSE`, 9,077 `NEUTRAL`.

If the engine polls every 30 to 60 seconds the production code uses the same time windows; the
replay still steps one minute at a time. Run the same replay with each minute's reading repeated at
+30 seconds: the same 18 changes must result (the reference code does; in the table's minute
resolution they are identical). The tests must also pass with the state written to JSON and read
back before every step.

Sensitivity worth knowing before changing anything: a sustain window of 1, 2, 4 or 5 samples gives
22, 20, 16 and 16 changes; a dwell of 9 or 11 minutes keeps 18 changes but moves their times.

**Synthetic cases (also required):**

- CO2 1250 with clean outdoor air is `OPEN`; with outdoor AQI 154 it is `CLOSE` (hazard); with 90 F
  and 70% RH outside it is `BRIEF` (and `OPEN` at CO2 1700).
- Indoor RH 64% with drier outdoor air is `OPEN`; dusty outdoor air by AirNow with clean indoor air
  is `CLOSE` (advisory, no alert).
- Indoor RH 73% alone is `CLOSE` (humidity), `BRIEF` if CO2 is also 1700; RH 67% with the dew point
  up 5 F is `CLOSE`, while RH 65% with the same rise is `NEUTRAL`.
- Indoor RH 73% with outdoor 66 F / 55% RH is `OPEN` (`HUMID, DRIER OUT`); with outdoor 78 F / 80%
  it is `CLOSE`; with drier outdoor air at 95 F it is `BRIEF`.
- VOC 180 alone is `NEUTRAL` with an annotation; VOC 270 is `OPEN`.
- Outdoor 95 F or 40 F with good indoor air is advisory `CLOSE` (not visible).
- OpenWeather-only PM2.5 13 with AQI 43 is `NEUTRAL`; OpenWeather-only PM2.5 40 is `CLOSE`
  (hazard). Stale air data skips the hazard rule; stale weather skips the temperature rules.
- CO2 1100 with tree pollen 85 is `BRIEF`; with weed or mold at 95 it stays `OPEN`; with CO2 1600
  it stays `OPEN`; pollen alone is `NEUTRAL`; a hazard stays `CLOSE`.
- Null, string or zero values in any outdoor field, and null indoor readings, never raise and never
  produce a verdict from the missing field.
- CO2 900 is `NEUTRAL` unless the CO2 latch is set, then `OPEN`; likewise PM2.5 7 with the PM latch.
- No alert text is ever longer than 29 characters (worst realistic cases are 25).
- A 20-minute outage inside the week resets the windows without raising and does not change the
  other transitions.

The week exercises only the VOC and humidity paths and one PM burst; the synthetic cases carry the
rest. The outdoor rules have not seen real history yet (see Open Items).

---

## Replay against seven days of real data

Run: 2026-10-01 00:00 through 2026-10-07 19:59 local, 9,840 one-minute samples from the
AirGradient history exports (CO2, PM2.5, VOC, temperature, humidity). Outdoor data was not
available for most of that period, so the replay is indoor-only. The stateful `Advisor` was used,
with the 10-minute dwell and 3-minute sustain filter.

| Episode | Verdict | Reason | What was happening |
| --- | --- | --- | --- |
| 10-01 21:18 to 10-02 01:59 | `OPEN` | VOC 338 (peak 475) | long VOC episode, cause unknown |
| 10-03 13:03 to 13:44 | `CLOSE` | humidity 70% (dew point +4 F in 30 min) | midday humidity rise |
| 10-04 11:49 to 14:31 | `CLOSE` | humidity 70% | humid midday; RH at or above 70% for 59 minutes |
| 10-04 19:07 to 19:17 | `OPEN` | VOC 250 | brief VOC spike |
| 10-04 20:37 to 23:13 | `OPEN` | VOC 263 (peak 310) | second long VOC episode, cause unknown |
| 10-06 11:03 to 11:15 | `OPEN` | indoor PM2.5 9.4 | vacuum burst |
| 10-06 20:08 to 20:18 | `OPEN` | VOC 257 | brief VOC spike |
| 10-07 06:39 to 07:16 | `CLOSE` | humidity 70% (dew point +4 F in 30 min) | morning humidity climb; showers 06:00 to 09:00 (indoor source); user closed the window |
| 10-07 08:30 to 09:24 | `CLOSE` | humidity 69% (dew point +4 F in 30 min) | second humidity hump (CO2 898); shower |

The two shower episodes would have been `OPEN` with the outdoor weather available at the time if
outdoor air was drier by 2 F of dew point or more; they stay `CLOSE` in this replay because it is
indoor-only. That is the one place where a live replay is expected to differ from this table.

Eighteen verdict changes in seven days (469 minutes `OPEN`, 294 minutes `CLOSE`, 9,077
`NEUTRAL`), versus the first draft's rules, which would have shown `OPEN` for 4,060 minutes on
the VOC rule alone. The CO2 rule never fired, correctly: CO2 reached 1,000 for a single minute
all week. The 19:28 window opening on 10-07 produced no alert, because CO2 was only about 620
ppm and humidity was normal, so there was no need to ventilate.

Tuning notes from the replays: the humidity trip's second clause originally fired at 65% RH
(10-07 11:45), which was too sensitive, so its RH floor was raised from 63% to 66%; and the
sustain filter was added after a single one-minute CO2 reading of 1,004 (10-02 13:46) produced
an `OPEN` alert.

---

## Observations that shaped the rules (2026-10-06 to 15)

- **Opening a window moves everything at once.** The 19:28 opening on 10-07 took CO2 from 619
  to 471 ppm (about 10 air changes per hour from a curve fit), VOC from 162 to 20, and RH
  down about 4 points, while PM2.5 rose 1.8x, PM10 2.1x and PM0.3 1.7x. The CO2/PM trade-off
  is real and recurring.
- **What a night with the windows open all night looks like here (2026-10-07 to 08, window state
  confirmed by the user afterwards; AC idle, setpoint 76 F, outdoor 61 to 64 F, outdoor PM2.5 7 to 9).**
  CO2 stayed at 457 to 551 ppm, about 500 to 530 through the night and creeping up to about 565 by 09:00,
  never falling to the roughly 420 to 470 that a daytime opening reaches; the room cooled from 75.7 to
  68.5 F; the indoor dew point fell only about 3 F (58.5 to 56.4) toward the outdoor 54 to 55; indoor PM2.5
  drifted up from 3.0 to 4.5 (PM10 about 7.6 and PM0.3 about 1,300 near midnight, against about 5 and 950
  on the closed-window night of 10-06). So an all-night opening reads as CO2 near the outdoor night-time
  level (assumed to be itself close to 500 ppm; it was not measured), not as a CO2 drop, and the
  distinguishing signals were the particle counts and the temperature slide, not CO2. A morning CO2 of
  600 or more then comes from being in the room (a step from about 565 to 610 at 09:25 when the room was
  occupied), not from the windows. This is why the CO2 rule is "insurance" and why CO2 alone cannot say
  whether the windows are open.
- **What closing the windows looks like (2026-10-08, closed at 15:38Z; midday, outdoor PM2.5 12 to 16, outdoor
  76 to 85 F, user at the desk).** With the windows open CO2 had been easing slowly (603 to 568 ppm over an hour);
  it bottomed out about 12 minutes after closing and then climbed (568 to about 700 over the next hour, with the
  room occupied). Particle counts fell about 10 percent over the next half hour (PM0.3 about 1,120 to about
  1,000; PM10 6.1 to about 5.5), a weak, slow signal because indoor PM stayed far below outdoor even with the
  windows open (indoor PM2.5 3.6 against 14 to 16 outdoors). Indoor temperature kept rising throughout (71.6 to
  73.9 F) because the outdoor air was warming, so by day it does not separate open from closed as it does at
  night. An hour later RH and dew point jumped together with CO2 (RH 59.8 to 65.9 percent, dew point 57.5 to
  61.4 F, 16:30 to 16:50Z), an indoor moisture source with the windows closed: the advisor moved to `BRIEF`
  ("indoor RH 60% and drier outside") on its own rules, which is what the humidity-with-outdoor-data rule is for.
- **The air handler measurably lowers CO2 (analysis of the Home Assistant archive, 2026-09-28 to 10-08, 14,900
  minutes; thermostat `climate.thermostat_cave`).** While the AC is cooling for more than half of a half hour,
  CO2 falls about 18 to 20 ppm per hour (median 13 to 15) in every time band; while the AC is idle it drifts up
  +3 (night), +10 (day) and +14 (evening) ppm per hour. The thermostat is in `Circulation` fan mode, so with the
  AC idle the fan pulses on its own, about 3 minutes on and 7 off (a 10-minute cycle, roughly 30 percent duty), and
  runs continuously while cooling; there are too few windows with the circulation fan alone at 50 percent duty or
  more to measure its effect. Net, a cooling hour moves CO2 about 25 to 35 ppm relative to an idle one: real and
  consistent, but an order of magnitude smaller than an open window (CO2 619 to 471 ppm in about 8 minutes on
  10-07). It also does not explain a night's baseline by itself: the nights with the most AC time (99 to 191
  minutes) ended around 533 to 546 ppm at 07:00, the AC-idle nights around 486 to 500, and the last (open-window,
  AC-idle) night 529, so occupancy earlier in the evening, window state and outdoor night-time CO2 (which can sit
  above a closed room's level) are mixed in and cannot be separated from this data. A ceiling fan turned to high at
  17:23Z on 10-08 changed nothing visible (CO2 607 to 627 over the next ten minutes): it stirs the room, it does not
  exchange air. For analysis, the AC and fan state should be inputs next to the sensor data.
- **CO2 cannot detect every window opening.** On the morning of 10-07 CO2 rose while the window
  was open (565 to 742 ppm), probably because someone was in the room. Humidity was the signal
  that showed it.
- **In this room, humidity and VOC are the working triggers.** Over the week CO2 stayed under
  700 except for a 917 peak on 10-07 and a one-minute 1,004; PM2.5 reached 9 only during the
  vacuum; RH reached 70% in five runs on three days. The CO2 and PM lines are insurance for an
  occupied or dusty room, not rules that will fire often here.
- **Three of the seven nights carry an outdoor-air signature** (night median PM10 5.0 to 6.0 and
  PM0.3 757 to 1,023, versus PM10 1.0 to 2.5 on the other four): the nights ending the mornings
  of 10-01, 10-04 and 10-07. CO2 fell 47 and 111 ppm over the first two and rose 24 ppm over the
  third. This is a pattern, not proof of window state.
- **Indoor moisture sources look like outdoor humidity.** On 10-07 showers between 06:00 and
  09:00 (bathroom door faces the sensor, bathroom exhaust fan inoperable) produced both humidity
  episodes, with dew point up about 5 F at nearly constant temperature. The humidity trip cannot
  tell this from humid outdoor air without outdoor data; with it, rule 2 now sends an indoor source
  with drier outdoor air to `OPEN`.
- **The AC changes temperature and humidity by itself.** Cooling at 07:12 to 08:02 on 10-07
  dropped the temperature 3.3 F and the dew point 5.7 F; RH sat at 53 to 54% while it ran on
  10-06 evening. Humidity rules should be read with `hvac_action` in mind.
- **Particulates do not clear quickly in this room once they are in.** After the 20:41 step on
  10-06, PM held roughly flat from about 22:00 to 05:30 (PM2.5 about 2.9, PM10 about 5,
  PM0.3 about 950). CO2 stopped falling at about 23:15 and then crept up, which fits the user's
  recollection of closing the window for the night; but that recollection of window state
  across the week is not fully reliable, and flat PM could also mean continuing outdoor
  infiltration, so this is not yet a clean closed-room decay measurement.

- **A sealed room does not decay, and an opened one clears in minutes (2026-10-14 to 15, window state and
  times reported by the user).** Windows closed all night, user in the room until about 03:00, then out until about
  10:40; AC cycling, setpoint 75 then 74 F. CO2 climbed from about 590 (18:00) to 798 ppm (02:30) with the user in
  the room. With the room empty it fell only while the AC ran (784 to 747, about 25 ppm per hour from 03:00 to
  04:45) and otherwise sat at 750 to 780 for eight hours, creeping up about 5 ppm per hour (748 at 05:00, 773 at
  10:30): no decay toward outdoor air at all. After re-entry it rose about 3 ppm per minute (773 to 836 in
  about 25 minutes). At 11:10 the user opened a window and set the ceiling fan to high (outdoor 84 to 86 F at 49 to 54%
  RH, wind from 240 degrees at 8 knots gusting 17, from the KMEM METAR): CO2 went 820, 688 (+2 min), 630 (+4),
  540 (+10), 502 (+12), and settled at about 490 (+13 to 16); VOC 198 to 20; RH 61 to 53%; temperature 75.1
  to 77.5 F (the indoor dew point barely moved, 60.8 to about 59 F, so the RH fall was the warming, not drier
  air); PM2.5 2.6 to 5.2. So the overnight plateau was an absence of fresh air, not a source or a slow
  sensor: the AC recirculates room air and brings in almost none. The rise to about 750 to 800 is what a day of
  occupancy adds to a closed room, and only outside air removes it. It also explains why morning CO2 was 400s
  with windows open or in cooler weather and 600 to 770 now. The advisor stayed NEUTRAL throughout (CO2 never
  reached `co2_enter` = 1000), so on days like this a lower `co2_enter` (about 800) would have said OPEN
  earlier; to be considered in the post-DST review rather than changed now. Wind direction is logged
  (`out_wind_*` columns) but not yet related to the clearing rate; this is a single test, with a window and a
  high ceiling fan together.

- **Closed window, same afternoon (2026-10-15, times from the user).** The window was shut at 11:37 local with the user at the
  desk, the ceiling fan on high, the AC idle (the Cave thermostat, in the second-floor hallway, read 75.5 F against a
  setpoint of 76 while the room sensor read 78 F). CO2 rose from about 490 at about 12 ppm per minute (500, 548 at +4 min,
  597 at +8, 629 at +13, 651 at +17) and levelled at about 655 from 11:56: a time constant of about 6 minutes, so the
  closed room still exchanged air quickly with something (the rest of the house through the door and the AC return, or
  leakage). It was therefore not a sealed room, and it levelled well below the 750 to 780 of the empty overnight plateau.
  The door state was not recorded at the time; the user confirms the office door is always open and has never been shut, so this and every other observation in this section was taken with the door open to the hallway. That points to the open door (the hallway, stairwell and balcony) as the path that exchanged air with the house while the window was shut. Whether the room trades air with the house or with outdoors, and how much the fan
  matters, is not yet separated; a repeat with the door shut (never measured) and the fan off would show it.
- **A shower, and a second airing (same afternoon).** A 30 minute shower from about 12:35 to 13:05 raised the indoor RH
  from 56 to 66% and the dew point from 61.8 to 67.3 F while CO2 went from 726 to about 805 ppm. The advisor changed to
  `BRIEF` at 13:03 ("indoor RH 65% and drier outside"; alert text `BRIEF OPEN // DRIER OUT`, the first alert shown with
  `shadow = false`) and back to `CLOSE` at 13:13: exactly the 10 minute dwell, while the windows were open and CO2 was
  still 673. Opening the windows at 13:10 took CO2 from 803 to 501 ppm in 16 minutes, the dew point from 67.6 to 62.6 F
  (RH 66 to 56%), VOC from 235 to 39, and the room temperature not at all (79.8 to 79.5 F, outdoor 90 F). The A/C started
  cooling at 13:08:36 (the thermostat reading rose to 76.5 F with the shower's heat) and ran for the whole airing, so this
  decay includes the AC, and the dew point fall includes its dehumidifying; the earlier 11:10 test, with the AC idle,
  is the clean one. Site layout (from the user): the office is over the garage; outside its door a hallway is open to the first floor on one
  side (stairwell and a balcony), so warm, CO2-laden house air rises up the stairs and, with the right air flow, fills
  the office area. That is consistent with a closed-window office that still trades air quickly with the house, with the
  room sensor reading about 4 F warmer than the Cave thermostat (which sits in the second-floor hallway between the stairs and the balcony, across from the stairs, where air from the first floor reaches it first, so the Cave zone is controlled by hallway air rather than office air; the house also has Main and Bed thermostats in Home Assistant, not yet exported), and with an empty-room overnight plateau near 750 (the
  the other adult in the house, who with a cat is the only other CO2 source, asleep downstairs; a guess, not measured); it is not yet separated from fan and door effects. No garage-exhaust signature shows in the
  data (the NOx index never exceeded 6 in 17 days). Note on the outdoor figures: temperature and RH come from OpenWeather's current conditions for the
  site coordinates (the weather provider), and the wind from the KMEM METAR (an airport about 13 miles away, flat and
  open). The site is a heavily wooded lot with tall trees, so the wind at the windows is certainly lower than the METAR
  and the shaded air is probably cooler than reported (the room did not warm at all with a reported 90 F outside). Trees
  would raise the local humidity, not lower it. In the 11:10 test the indoor dew point stayed at or below the reported
  outdoor figure (a dew point near 65 F; indoor 60.8 to about 59 F), so the reported humidity may read high compared
  with the air at the window; not settled, and the AC confounds the second airing. Watch it in the post-DST review,
  because the "drier outside" rule depends on it.

- **A cold-front morning with the windows open (2026-10-16, times from the user).** The office windows face south. After
  a night with the room empty and the AC idle but the air handler fan running continuously (CO2 fell slowly, 608 at 04:00
  to 581 at 06:20, about 10 ppm per hour, the opposite of the previous night's creep), the user opened the windows at 06:25
  with the ceiling fan on low. The front had already passed: reported outdoor 68 F, 77% RH (a dew point near 61 F, only
  1 to 2 F below the 62 F of the previous afternoon, so the drier air lagged the wind shift), wind from 350 degrees at 14
  knots (METAR). With the wind from the north the south-facing windows are on the leeward side, and the CO2 floor
  (where the occupant's output balances the exchange, user at the desk) was about 520 ppm, about 100 above outdoor air,
  against about 480 on 10-15 when the southwest wind blew straight in with the fan on high. As the METAR wind rose to 16
  knots gusting 28 the floor fell to about 470 (07:06 local); the user felt the air arrive in gusts. The room cooled only
  0.9 F in the first hour (75.2 to 74.3 F) with 65 to 67 F outside, and the outdoor dew point fell to about 57.5 F, about 2 F
  below the room's 59 F. The advisor stayed `NEUTRAL` (no need: CO2 under 1000, RH 59%); a cool, dry morning by itself is
  not a trigger in the current rules. The METAR wind is the airport's open-field wind; what matters at the windows is
  its direction relative to them as well as its speed, and the log has no window orientation, so this stays an annotation
  for the review, not an input.

- **The sensor recalibrates itself (2026-10-16).** The AirGradient's CO2 sensor has automatic baseline correction (ABC) set to 8 days
  (`select.cave_airgradient_cave_co2_automatic_baseline_duration`): it treats the lowest reading of each period as fresh air
  (about 400 ppm) and shifts its baseline to match. The hourly statistics show the daily minimum at 400 to 440 through
  September, then 350 to 385 on 09-23 to 09-25 and 369 on 09-28 (below any real outdoor level, so the sensor was reading low by
  several tens of ppm), then 481 to 525 from 09-29 to 10-03. The step up of about 100 ppm that this document attributes to the AC
  and closed windows on 09-28 may therefore include an ABC correction; the two are not separated. Since then the open-window
  floors (380 to 405 ppm, 2026-10-16) agree with outdoor air. A long run of closed-window AC days (no reading near 400 in the
  period) makes ABC pull the baseline down, so CO2 would read low; to be considered in the review (a longer period, or a
  manual calibration after a long airing). The setting was left alone while the data set is being collected.

- **The room holds its heat (2026-10-16).** After more than six hours of open windows with a CO2 time constant of a few minutes
  (the air is replaced every 6 to 8 minutes), the room fell only from 75.2 to 71.9 F, about 0.5 F per hour, while the outdoor air
  fell from 68 to 61 F: the gap widened from 7 to 11 F. The air carries almost no heat; the structure, the furnishings, the open
  hallway to the warm first floor and, the user believes, heat stored in the garage below (the office is over the garage, and the
  user reports it gets very cold in winter, which would be the same coupling in reverse) supply it. No garage temperature is
  recorded anywhere (Home Assistant has none), so the garage effect is a hypothesis. Consequence for the rules: the free-cooling
  need (`cool_indoor` 78 F, `cool_delta` 5 F) describes air that is cooler, not a room that will follow it; expect a night of open
  windows to lower this room by only a few degrees.

- **A full night of open windows in cool weather (2026-10-16 to 17, user reports; door open, ceiling fan low, windows open since
  06:25 on the 16th, room empty overnight).** Room temperature 71.9 F at 18:00, 68.6 at 00:00, 66.9 at 04:00, 65.7 at 06:00 and
  64.4 at 10:00, while the outdoor air fell from 61 F to 54 F at midnight and a low of 51 F at 06:00 to 08:00 (Home Assistant's
  weather entity). That is 7.5 F in 16 hours, about 0.45 F per hour, and the 13 to 15 F gap to the outdoor air never closed. A rate
  of 0.45 F per hour against a gap of about 15 F is a thermal time constant of roughly 30 to 35 hours (rough: the open hallway and
  the warm first floor keep supplying heat). CO2 stayed at 413 to 439 ppm all night, the outdoor level, so with the room empty
  nothing accumulates and the open windows hold it at the floor. The indoor dew point stayed at 46 to 50 F (RH 44 to 54%, rising only
  because the room cooled). The advisor changed to an advisory `CLOSE` at 01:27 when the outdoor temperature fell below 55 F (never
  shown) and stayed quiet, which suits a comfort question the occupant decides. The provider was not running from 01:43 to 11:45
  local (machine off); the indoor record for that stretch comes from the Home Assistant export.

- **The office against the rest of the house (same night, from the zone thermostats exported 2026-10-16).** Downstairs windows
  closed, only the office windows open. Temperature in F at 18:00, 00:00, 06:00 and 10:00: Main zone 74.4, 72.4, 70.4, 70.4;
  Bedroom zone 74.4, 73.4, 71.4, 70.4; hallway (the Cave thermostat, mode off) 71.4, 70.4, 68.4, 67.4; office sensor 71.9,
  68.6, 65.7, 64.4, while the outdoor air fell from 61 to 51 F. Main and Bedroom lost about 4 F in 16 hours (about 0.25 F per
  hour against a 20 F gap, a time constant near 80 hours: a well insulated house with a lot of mass), the hallway also about
  4 F, the office 7.5 F, ending 6 F below Main and Bedroom. The office is the weak spot, as the user suspects (least insulated
  room, over the unconditioned garage, cold through the floor in winter), but this night cannot separate the floor from the open
  windows, which only the office had. A winter comparison with the windows shut (office against hallway and Main), or a garage
  temperature sensor, would. The garage door openers (myQ) once reported the garage temperature but dropped off the network
  and Home Assistant's myQ support ended in 2023, so they are not a data source today.

- **Heat rising from downstairs, with the office windows as an outflow (2026-10-18, the user's reading).** The Cave (upstairs) unit is
  normally left off in winter: the heat that rises from the first floor, up the stairs and across the open balcony hallway usually
  warms the upstairs enough. With the office windows open there is an exit at the top, so more warm air should flow through the
  office on its way out, and with the wind from the north the south-facing windows are on the leeward side, where the wind pulls
  air out. If so, the replacement air for the office enters low in the house (leaks, doors) rather than through the office
  windows, so the office CO2 reflects the house air: it sat at the outdoor level (about 430 ppm) in a north wind. On 10-18 at about
  10:14 the Main and Bedroom thermostats were switched from cool to heat (setpoints 68 and 70); by 10:30 Bedroom had risen 1.1 F,
  Main 0.1 F and the hallway (Cave thermostat) 0.1 F, while the office sensor rose 1.8 F in 18 minutes, which sun through the open south
  windows (clear sky), the occupant and a steady 340 W on the "Computers" plug (not confirmed to be in the office) can also
  explain. The user could feel the heat at the balcony within about 20 minutes. A second AirGradient downstairs (planned for the Great Room)
  would show whether the house air is at the office's level (flow through the house) or not; a tissue or smoke test at the
  window would show the direction of the air. By the 09:54 local METAR (14:54Z) the wind had shifted from the north to 130 degrees at 3 knots, with a clear TAF (the
  windward side of south-facing windows, but light).

- **Where things are in the office, and what the first hour of downstairs heat showed (2026-10-18, from the user's photos).** The
  AirGradient stands on a wire shelf against a side wall, about 4 to 5 feet from the desk and some 15 feet from the south windows,
  out of direct sun; a ceiling supply register (the office is ducted to the Cave unit, whose fan still pulses in Circulation mode
  with the unit off) is about 8 to 10 feet away on the same side; the PC tower stands right at the windows in the sun, drawing
  about 340 W; the room has sheer curtains and a cat tree at the windows; the Cave thermostat is on the hallway wall at the head of
  the stairs, opposite the open balcony. After the Main and Bedroom thermostats were switched to heat at about 10:14, the hallway
  (Cave unit off) read 63.4 F until about 10:29, then 64.5 at 10:39 and 65.5 at 10:51: heat from downstairs reached the
  hallway in about 25 minutes and then added about 1 F per 12 minutes. The office sensor rose faster (59.5 F at 10:10 to 64.9 at 10:57,
  then back to 63.7 at 11:13), so the sun and the computer, not only the hallway, drive it. The Cave fan's pulses leave a
  small signature in the office sensor (over the last day: CO2 falls about 0.3 ppm per minute with the fan on and rises about 0.2
  ppm per minute with it off; temperature and humidity show nothing), so the register does not dominate what the sensor reads.

---

## Open Items

- Thresholds are defaults. A week of history has been replayed once; revisit after a few more weeks
  and in a different season, particularly the VOC 250 line (two long episodes need an explanation;
  consider a release near 200), the 70% / 66% humidity thresholds, and the 55 to 85 F outdoor comfort
  band, which no history yet exercises because outdoor temperature was not logged. The shadow
  week's input log (see the provider document) is meant to close this.
- The new outdoor rules (humidity with drier outdoor air, free cooling, AirNow PM comparisons,
  pollen weighing) are covered by synthetic cases only.
- AirNow's overlay was usually empty in the air cache until 2026-10-07: the air provider took
  AirNow's `RawConcentration = -999` (not yet available) instead of `Value` and discarded the newest
  hour. Fixed in `fetch_air.sh`, with `max_age_sec = 7200` in the example profile (see
  `env-provider-status.md`). The provider also picks the nearest monitor per pollutant now.
  `pm_source` is `owm` only when AirNow has nothing under 2 hours old.
- Whether OSA shows the verdict as a status-line tag, a color on the ENV panel header, or
  only as a transient alert.
- NOx index (1 to 6 all week) is not used; it is logged by the provider design but never
  approached a level worth an alert.
- Pollen stays on the static seasonal curve unless a live source becomes free and accurate
  enough to justify the change; that would be a new core provider domain, not part of `air`.
- `pollen_mem_v1.csv` and `pollen_mem_v2.csv` disagree on mold (v1 peaks earlier and
  declines sooner); the advisor reads v2, the same file `env.lua` reads.
- A window contact sensor and `hvac_action` from Home Assistant would let the advisor say "close the
  windows" only when they are actually open, and allow a "windows open while the AC is cooling"
  alert. That needs Home Assistant access in the engine, which it does not have.
