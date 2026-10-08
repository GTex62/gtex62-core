# providers/airgradient/ventilation_advisor.py
# Engine-side ventilation advisor (open / close windows) for the airgradient domain.
#
# Everything below the dashed line is the reference implementation from
# docs/ventilation-advisor-design.md, verbatim; tests/airgradient/test_advisor.py
# fails if the two drift apart. Change the design doc and this file together.
# Pure Python standard library, no I/O: the provider (fetch_airgradient.py) owns
# reading inputs, persisting state and writing status.json.
# ---------------------------------------------------------------------------
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
            escalated = self.severity == 'normal' and r['severity'] == 'severe' and r['verdict'] != 'NEUTRAL'
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
