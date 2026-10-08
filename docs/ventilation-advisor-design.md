# Ventilation Advisor (Open / Close Windows)

Engine-side classification that compares indoor AirGradient readings against outdoor
air and weather data and produces a single verdict: do conditions favor opening the
windows, keeping them closed, or does it not matter. Intended as a section of
`airgradient-provider-design.md` (the "classification layer" noted under *Raw values now,
classification later*), written next to the raw fields the same way `PIA: HEALTHY` sits
beside `connectionstate`.

OSA displays the verdict and raises the alert. It does not compute it.

Revision 3 (2026-10-07): VOC demoted from a trigger to an annotation, indoor humidity trip
added, hysteresis, dwell and a 3-minute sustain filter now part of the tested reference code.
Checked against seven days of history (Oct 1 to Oct 7, 9,840 one-minute samples); the
thresholds are still defaults to be tuned (see Open Items).

---

## Inputs

| Side | Fields | Source |
| --- | --- | --- |
| Indoor | `co2_ppm`, `voc_index`, `pm.pm25_ugm3`, `temp_f`, `humidity_pct` | `shared/airgradient/<profile>/status.json` |
| Indoor (derived) | `dp_rise_30`: indoor dew point now minus 30 minutes ago (F), computed from `temp_f` and `humidity_pct` | engine keeps a 30-minute history |
| Outdoor air | `selected.pm2_5`, `selected.pm10` (µg/m³), `airnow.aqi`, `provider_updated_at` | `shared/air/<profile>/current.json` |
| Outdoor weather | temperature (F), relative humidity | weather provider cache (field names to confirm) |
| Pollen (optional) | `tree`, `grass`, `weed`, `mold` (0 to 100 seasonal index) | `pollen_mem_v2.csv`, day-of-year lookup; the same file `env.lua` reads |
| HVAC (optional, context only) | `hvac_action`, setpoint | Home Assistant thermostat entity |

Outdoor temperature and humidity are optional. If they are missing, the outdoor temperature
and humidity rules are skipped and the indoor rules (humidity trip, CO2, PM, VOC) still run.

---

## Verdicts

| Verdict | Meaning | Alert text |
| --- | --- | --- |
| `OPEN` | Indoor air needs ventilating and nothing outside argues against it | "Open windows: <reasons>" |
| `BRIEF` | Indoor need exists but outdoor conditions or humidity are a drawback | "Air out briefly (5-10 min): <need>; but <drawbacks>" |
| `CLOSE` | Outdoor conditions or indoor humidity are worse reasons to ventilate | "Close windows: <reasons>" / "Keep windows closed: <reasons>" |
| `NEUTRAL` | Either is fine | no alert |

The verdict means "conditions favor", not "windows are currently open". There is no window
sensor, so the advisor cannot know the actual window state.

---

## Rules (evaluated in this order)

1. **Hard close**: outdoor AQI >= 101, outdoor PM2.5 >= 35.5 µg/m³, or outdoor PM10 >= 155.
   Verdict is `CLOSE` regardless of indoor readings. If indoor CO2 is also >= 1000, the
   message adds "use an air purifier or a very short airing". Skipped if the outdoor data is
   stale (see below).
2. **Indoor humidity trip** (indoor data only, so it works with no outdoor data):
   - Enter when indoor RH >= 70%, **or** indoor RH >= 66% with the dew point up 4 F or more
     in 30 minutes.
   - Release when RH < 66% **and** the 30-minute dew point rise is below 2 F.
   - Verdict is `CLOSE` ("Close windows: humidity 73%"). If need is severe (CO2 >= 1500 or
     VOC >= 250) it is `BRIEF` instead.
3. **Indoor need** (any one triggers):
   - CO2 >= 1000 ppm
   - VOC index >= 250 (severe; see *VOC* below)
   - indoor PM2.5 >= 9 µg/m³ **and** at least 3 µg/m³ above outdoor PM2.5
   - indoor RH >= 60% and outdoor dew point at least 2 F lower than indoor dew point
   - indoor > 78 F and outdoor at least 5 F cooler (free cooling)
4. **Outdoor drawbacks** (soft, any one counts):
   - outdoor temperature above 85 F or below 55 F
   - outdoor dew point at least 2 F above indoor dew point while indoor RH >= 50%
   - outdoor PM2.5 above 9 µg/m³ and at least 3 µg/m³ above indoor PM2.5
5. **Combine**: need and no drawback is `OPEN`. Need with a drawback is `BRIEF`, except that
   severe need (CO2 >= 1500 or VOC >= 250) is `OPEN` regardless. No need but a drawback is
   `CLOSE`. Neither is `NEUTRAL`.
6. **Pollen (annotation, optional nudge)**: pollen is considered but never decides the verdict
   on its own.
   - The message always appends any category at or above 50, e.g. `| pollen: mold 91, weed 65`.
   - If `pollen_sensitive = true` (default `false`) and the verdict is `OPEN`, the verdict is
     downgraded to `BRIEF` when tree, grass or weed is at or above `pollen_threshold`
     (default 80). Mold is excluded unless `pollen_include_mold = true`.

**VOC.** The AirGradient VOC index is relative to a baseline the sensor learns over about
120 hours, so an absolute threshold is a poor trigger. Over the week the index sat at 150 or
above for 4,060 of 9,840 minutes (41%); the daily median was 160 to 191 on Oct 1 to 3. It also
climbs smoothly for hours with CO2 and PM flat, which looks like the sensor's own scaling and
not a real source. A VOC of 150 to 249 is therefore shown as an annotation only. 250 or higher
still counts as need: that was 455 minutes (4.6%) in five episodes, two of them long (Oct 1
21:16 to Oct 2 01:58, peak 475; Oct 4 20:35 to 23:12, peak 310). If those match a real activity
the advice to ventilate is right; if not, they are the sensor's scaling and this line may need
to rise.

**Why pollen is soft.** The values come from a static seasonal curve, not a measurement. Live
pollen sources were evaluated and set aside: they cost money, local values are not free, and
they are not very accurate; a local sensor means expense and setup. The seasonal curve was the
deliberate compromise. It also cannot see today's weather (rain, wind), and in
`pollen_mem_v2.csv` mold is at or above 80 for about 130 days a year (mid-June to early
November), so using it as a trigger would block the windows for a third of the year.

Compare **dew point**, not relative humidity: RH depends on temperature, so 70% RH outside
at 60 F is drier air than 55% RH inside at 73 F. The same applies to the humidity trip's second
clause: it watches dew point rise (moisture added), because RH alone also moves when the
temperature does. Observed example: on 2026-10-07 RH went from 63% to 73% between 06:15 and
06:48 while the temperature rose only 1 F and the dew point rose from 57.0 F to 61.8 F.

The absolute floors (9 µg/m³ PM2.5, 1000 ppm CO2, 55 to 85 F, 70% RH) are what keep the advisor
from nagging when everything is already good: outdoor PM2.5 of 5 versus indoor 2 is not worth
an alert. The numbers follow common guidelines (the EPA "Good" ceiling for PM2.5, the usual
1000 ppm CO2 comfort line) and are meant to be tuned.

---

## Alert behavior

- **Alert on verdict change only**, not on every poll.
- **Hysteresis** so values near a threshold do not flap: enter `OPEN` for CO2 at >= 1000
  but leave it below 800; enter on indoor PM2.5 >= 9 but leave below 6; humidity trip as in
  rule 2.
- **Minimum dwell** of 10 minutes before the published verdict can change again.
- **Sustain filter**: CO2, PM2.5 and VOC use the minimum of the last 3 one-minute samples, so a
  single-minute spike cannot trigger an alert (a one-minute CO2 reading of 1,004 on Oct 2 would
  otherwise have).
- **Stale outdoor data**: if `provider_updated_at` is older than 2 hours, ignore the outdoor
  PM comparison and the hard-close rule, and use indoor-only logic. Add `"outdoor_stale": true`
  to the output so OSA can show it.
- **Disabled/degraded**: if the AirGradient state is not `ok`, output no verdict.

---

## Output (added to `status.json`)

```json
"vent": {
  "verdict": "OPEN",
  "reason": "Open windows: indoor PM2.5 14.6",
  "outdoor_stale": false,
  "pollen": { "tree": 0, "grass": 0, "weed": 65, "mold": 91, "source": "seasonal-curve" }
}
```

---

## Reference implementation (tested)

```python
import math

def dewpoint_f(temp_f, rh):
    c = (temp_f - 32) / 1.8
    a, b = 17.62, 243.12
    g = math.log(rh / 100.0) + a * c / (b + c)
    return (b * g / (a - g)) * 1.8 + 32

def humid_trip(rh, rise, latched):
    """Entry: RH >= 70, or RH >= 66 with dew point up >= 4F in 30 min.
    Release (hysteresis): RH < 66 and dew point rise < 2F."""
    if rh >= 70 or (rh >= 66 and rise >= 4): return True
    return latched and (rh >= 66 or rise >= 2)

def advise(indoor, outdoor=None, latched=frozenset()):
    need, block, notes = [], [], []
    o = outdoor or {}
    fresh = bool(o) and o.get('fresh', True)
    rh, rise = indoor['rh'], indoor.get('dp_rise_30') or 0

    # 1. hard close: outdoor air hazardous
    if fresh and ((o.get('aqi') or 0) >= 101 or o.get('pm25', 0) >= 35.5 or o.get('pm10', 0) >= 155):
        return ('CLOSE', 'Close windows: outdoor air quality is poor' +
                (' (CO2 is high; use an air purifier or a very short airing)' if indoor['co2'] >= 1000 else ''))

    severe = indoor['co2'] >= 1500 or indoor['voc'] >= 250

    # 2. indoor humidity trip (needs no outdoor data)
    if humid_trip(rh, rise, 'humid' in latched):
        why = f"humidity {rh:.0f}%" + (f" (dew point {rise:+.0f}F in 30 min)" if rise >= 2 else '')
        if severe: return ('BRIEF', 'Air out briefly (5-10 min): CO2/VOC high; but ' + why)
        return ('CLOSE', 'Close windows: ' + why)

    # 3. indoor need
    if indoor['co2'] >= 1000 or ('co2' in latched and indoor['co2'] >= 800): need.append(f"CO2 {indoor['co2']:.0f} ppm")
    if indoor['voc'] >= 250: need.append(f"VOC index {indoor['voc']:.0f}")
    if (indoor['pm25'] >= 9 or ('pm' in latched and indoor['pm25'] >= 6)) and (not fresh or indoor['pm25'] >= o.get('pm25', 0) + 3):
        need.append(f"indoor PM2.5 {indoor['pm25']:.1f}")
    if o.get('temp_f') is not None and o.get('rh') is not None:
        dp_in, dp_out = dewpoint_f(indoor['temp_f'], rh), dewpoint_f(o['temp_f'], o['rh'])
        if rh >= 60 and dp_out <= dp_in - 2: need.append(f"indoor RH {rh:.0f}% and drier outside")
        if dp_out >= dp_in + 2 and rh >= 50: block.append('outdoor air is more humid')
    if o.get('temp_f') is not None:
        if o['temp_f'] > 85 or o['temp_f'] < 55: block.append(f"outdoor {o['temp_f']:.0f}F")
        elif indoor['temp_f'] > 78 and o['temp_f'] <= indoor['temp_f'] - 5: need.append('free cooling available')
    if fresh and o.get('pm25', 0) > 9 and o.get('pm25', 0) >= indoor['pm25'] + 3: block.append(f"outdoor PM2.5 {o['pm25']:.0f}")

    # 4. VOC 150-249: annotation only (index is relative to a learned baseline)
    if 150 <= indoor['voc'] < 250: notes.append(f"VOC index {indoor['voc']:.0f} (relative, informational)")
    tail = (' | ' + '; '.join(notes)) if notes else ''

    if need and (not block or severe): return ('OPEN', 'Open windows: ' + ', '.join(need) + tail)
    if need and block: return ('BRIEF', 'Air out briefly (5-10 min): ' + ', '.join(need) + '; but ' + ', '.join(block) + tail)
    if block: return ('CLOSE', 'Keep windows closed: ' + ', '.join(block) + tail)
    return ('NEUTRAL', 'Fine either way' + tail)

class Advisor:
    """Stateful wrapper: hysteresis latches plus a minimum dwell between verdict changes."""
    def __init__(self, dwell_min=10, sustain=3):
        self.latched, self.verdict, self.reason, self.since, self.dwell = set(), 'NEUTRAL', 'Fine either way', None, dwell_min
        self.sustain, self.hist = sustain, []
    def _latch(self, ind):
        rh, rise = ind['rh'], ind.get('dp_rise_30') or 0
        for name, enter, release in (('co2', ind['co2'] >= 1000, ind['co2'] < 800),
                                     ('pm',  ind['pm25'] >= 9,   ind['pm25'] < 6)):
            (self.latched.add if enter else self.latched.discard if release else (lambda _: None))(name)
        (self.latched.add if humid_trip(rh, rise, 'humid' in self.latched) else self.latched.discard)('humid')
    def step(self, t, ind, outdoor=None):
        """Returns True when the published verdict changed (i.e. an alert should fire).
        CO2, PM2.5 and VOC use the minimum of the last `sustain` samples, so a one-minute spike
        (someone breathing on the sensor) cannot trigger an alert."""
        self.hist = (self.hist + [ind])[-self.sustain:]
        ind = dict(ind, **{k: min(h[k] for h in self.hist) for k in ('co2', 'pm25', 'voc')})
        self._latch(ind)
        v, r = advise(ind, outdoor, frozenset(self.latched))
        if v == self.verdict:
            self.reason = r; return False
        if self.since is None or (t - self.since).total_seconds() >= self.dwell * 60:
            self.verdict, self.reason, self.since = v, r, t; return True
        return False
```

### Pollen layer (tested)

```python
def advise_with_pollen(indoor, outdoor, pollen=None, sensitive=False, include_mold=False, threshold=80):
    verdict, reason = advise(indoor, outdoor)
    if not pollen:
        return verdict, reason
    high = {k: pollen[k] for k in ('tree', 'grass', 'weed', 'mold') if pollen.get(k, 0) >= 50}
    note = 'pollen: ' + ', '.join(f'{k} {v}' for k, v in sorted(high.items(), key=lambda kv: -kv[1])) if high else ''
    keys = ('tree', 'grass', 'weed') + (('mold',) if include_mold else ())
    if sensitive and verdict == 'OPEN' and any(pollen.get(k, 0) >= threshold for k in keys):
        verdict, reason = 'BRIEF', reason.replace('Open windows', 'Air out briefly (5-10 min)') + '; but pollen is high'
    return verdict, (reason + ' | ' + note) if note else reason
```

With 2026-10-06 values (weed 65, mold 91) and calm indoor air the result is
`NEUTRAL: Fine either way | pollen: mold 91, weed 65`. With CO2 1250 it stays `OPEN`
unless `pollen_sensitive` is on and tree, grass or weed is at or above the threshold
(weed 90 gives `BRIEF`). A mold-only spike of 95 gives `OPEN` unless `pollen_include_mold`
is also set.

---

## Replay against seven days of real data

Run: 2026-10-01 00:00 through 2026-10-07 19:59 local, 9,840 one-minute samples from the
AirGradient history exports (CO2, PM2.5, VOC, temperature, humidity). Outdoor data was not
available for most of that period, so the replay is indoor-only (outdoor treated as stale).
The stateful `Advisor` was used, with the 10-minute dwell and 3-minute sustain filter.

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

Eighteen verdict changes in seven days (469 minutes `OPEN`, 294 minutes `CLOSE`, 9,077
`NEUTRAL`), versus the first draft's rules, which would have shown `OPEN` for 4,060 minutes on
the VOC rule alone. The CO2 rule never fired, correctly: CO2 reached 1,000 for a single minute
all week. The 19:28 window opening on 10-07 produced no alert, because CO2 was only about 620
ppm and humidity was normal, so there was no need to ventilate.

Tuning notes from the replays: the humidity trip's second clause originally fired at 65% RH
(10-07 11:45), which was too sensitive, so its RH floor was raised from 63% to 66%; and the
sustain filter was added after a single one-minute CO2 reading of 1,004 (10-02 13:46) produced
an `OPEN` alert.

Synthetic cases behave as intended: CO2 1250 with clean outdoor air is `OPEN`; the same with
outdoor AQI 154 is `CLOSE`; with 90 F / 70% RH outside it is `BRIEF` (and `OPEN` at CO2 1700);
indoor RH 64% with drier outdoor air is `OPEN`; dusty outdoor air with clean indoor air is
`CLOSE`; indoor RH 73% alone is `CLOSE`, and `BRIEF` if CO2 is also 1700; RH 67% with the dew
point up 5 F is `CLOSE`, while RH 65% with the same rise is `NEUTRAL`; VOC 180 alone is
`NEUTRAL` with an annotation, VOC 270 is `OPEN`.

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
  vacuum; RH reached 70% in four episodes on three days. The CO2 and PM lines are insurance for an occupied or
  dusty room, not rules that will fire often here.
- **Three of the seven nights carry an outdoor-air signature** (night median PM10 5.0 to 6.0 and
  PM0.3 757 to 1,023, versus PM10 1.0 to 2.5 on the other four): the nights ending the mornings
  of 10-01, 10-04 and 10-07. CO2 fell 47 and 111 ppm over the first two and rose 24 ppm over the
  third. This is a pattern, not proof of window state.
- **Indoor moisture sources look like outdoor humidity.** On 10-07 showers between 06:00 and
  09:00 (bathroom door faces the sensor) produced both humidity episodes, with dew point up
  about 5 F at nearly constant temperature. The humidity trip cannot tell this from humid
  outdoor air without outdoor data. With outdoor dew point available, the CLOSE reason should
  be worded "indoor humidity" and only advise closing when outdoor air is not drier; an
  indoor source with drier outdoor air is an OPEN case.
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

- Weather cache field names for outdoor temperature and humidity.
- Whether OSA shows the verdict as a status-line tag, a color on the ENV panel header, or
  only as a transient alert.
- Thresholds are defaults. A week of history (CO2, PM0.3/1/2.5/10, VOC, NOx, humidity,
  temperature, thermostat) has been replayed once; revisit after a few more weeks and in a
  different season, particularly the VOC 250 line (two long episodes need an explanation), the
  70% / 66% humidity thresholds, and the 55 to 85 F outdoor comfort band, which no history yet
  exercises because outdoor temperature was not logged.
- NOx index (1 to 6 all week) is not used; it is logged by the provider design but never
  approached a level worth an alert.
- Pollen stays on the static seasonal curve unless a live source becomes free and accurate
  enough to justify the change; that would be a new core provider domain, not part of `air`.
- `pollen_mem_v1.csv` and `pollen_mem_v2.csv` disagree on mold (v1 peaks earlier and
  declines sooner); the advisor should read the same file `env.lua` does (v2).
- A window contact sensor in Home Assistant would let the advisor say "close the windows"
  only when they are actually open, and would remove the need to rely on memory about which
  nights the windows were open. Together with `hvac_action` it would also allow a
  "windows open while the AC is cooling" alert.
