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
| Outdoor air | `airnow.aqi`; `selected.pm2_5` and `.pm10` (AirNow where present, else OpenWeather); `openweather.components.pm2_5` and `.pm10` | `shared/air/<air_profile>/current.json` |
| Outdoor weather | `temp_f`, `humidity_pct` | `shared/weather/<weather_profile>/current.json` |
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

- **Alert on verdict change only**, not on every poll. A change of verdict, or severity going from
  `normal` to `severe` under the same verdict, starts a new alert.
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

def humid_trip(rh, rise, latched, c=DEFAULTS):
    """Entry: RH >= 70, or RH >= 66 with dew point up >= 4F in 30 min.
    Release (hysteresis): RH < 66 and dew point rise < 2F."""
    if rh >= c['rh_enter'] or (rh >= c['rh_floor'] and rise >= c['rise_enter']):
        return True
    return latched and (rh >= c['rh_floor'] or rise >= c['rise_leave'])

def advise(ind, out=None, latched=frozenset(), pollen=None, cfg=None):
    """Pure rule evaluation. `ind` holds sustained co2/pm25/voc (None while the
    sustain window is not yet warm), instantaneous temp_f/rh, and dp_rise_30.
    `out` (all keys optional): aqi, pm25, pm10 (the air cache's `selected` values), pm_source
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

    # 5. pollen: annotation always; a soft drawback only when there is a need to weigh it against
    pol = pollen or {}
    notes = []
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
        self.cls, self.alert_text = 'none', ''
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
            escalated = self.severity == 'normal' and r['severity'] == 'severe' and r['verdict'] != 'NEUTRAL'
            self.reason, self.severity, self.cls, self.alert_text = \
                r['reason'], r['severity'], r['cls'], r['alert_text']
            if escalated:
                self.alert_since = t
                return 'escalate'
            return None
        if self.since is None or t - self.since >= c['dwell_s']:
            self.verdict, self.severity, self.reason = r['verdict'], r['severity'], r['reason']
            self.cls, self.alert_text = r['cls'], r['alert_text']
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

## Observations that shaped the rules (2026-10-06 and 07)

- **Opening a window moves everything at once.** The 19:28 opening on 10-07 took CO2 from 619
  to 471 ppm (about 10 air changes per hour from a curve fit), VOC from 162 to 20, and RH
  down about 4 points, while PM2.5 rose 1.8x, PM10 2.1x and PM0.3 1.7x. The CO2/PM trade-off
  is real and recurring.
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
