#!/usr/bin/env python3
"""Regression cases for providers/modem/fetch_modem.py's T3-timeout counting
(matches_t3() / compute_recent_t3()).

Not wired into any CI — this repo has no test runner today. Run directly:

    python3 providers/modem/test_fetch_modem_regressions.py

Each case here traces back to a real, live-captured incident, not an
invented shape — see docs/network-providers-roadmap.md's "Modem-Level
Corroboration Provider" session logs (Aug 31, 2026 and Sept 6/7, 2026) for
the full investigation each one closed out. Kept as a standalone script
(not synthetic-only fixtures) specifically so a future incident can be
dropped in here the same way, per the Sept 6/7 session's "lock it in
rather than relying on synthetic coverage alone" conclusion.
"""
import importlib.util
import sys
from datetime import datetime
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "fetch_modem", Path(__file__).parent / "fetch_modem.py"
)
fm = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(fm)

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


# ---------------------------------------------------------------------
# Aug 31, 2026 — LastTime="Time Not Established" fallback to FirstTime.
# Real row captured live that day: valid FirstTime, LastTime placeholder,
# large repeat count (2416) from an in-progress T3 burst. Before the fix,
# this row was dropped outright; the fix falls back to FirstTime.
# ---------------------------------------------------------------------
def test_unparseable_lasttime_falls_back_to_firsttime():
    now_dt = datetime(2026, 8, 31, 12, 0, 0)
    events = [{
        "docsDevEvId": "82000200",
        "docsDevEvText": "No Ranging Response received - T3 time-out;",
        "docsDevEvFirstTime": "2026-08-31, 11:45:00",
        "docsDevEvLastTime": "Time Not Established",
        "docsDevEvCounts": "2416",
    }]
    total, note = fm.compute_recent_t3(events, 60, now_dt)
    check(
        "Aug 31: unparseable LastTime, valid FirstTime -> counted via fallback",
        total == 2416 and note is None,
        f"total={total} note={note!r}",
    )


def test_both_timestamps_unparseable_excluded_with_note():
    now_dt = datetime(2026, 8, 31, 12, 0, 0)
    events = [{
        "docsDevEvId": "82000200",
        "docsDevEvText": "No Ranging Response received - T3 time-out;",
        "docsDevEvFirstTime": "garbage",
        "docsDevEvLastTime": "Time Not Established",
        "docsDevEvCounts": "99",
    }]
    total, note = fm.compute_recent_t3(events, 60, now_dt)
    check(
        "Aug 31: both timestamps unparseable -> excluded, surfaced via note",
        total == 0 and note is not None and "1 matching event row" in note,
        f"total={total} note={note!r}",
    )


def test_82000500_id_variant_matches():
    ev = {
        "docsDevEvId": "82000500",
        "docsDevEvText": "Started Unicast Maintenance Ranging - No Response received - T3 time-out;",
    }
    check("Aug 31: 82000500 ID variant recognized as T3", fm.matches_t3(ev))


def test_ucd_invalid_alone_not_counted_as_t3():
    ev = {
        "docsDevEvId": "85000200",
        "docsDevEvText": "UCD invalid or channel unusable;",
    }
    check(
        "Aug 31: bare 'UCD invalid' (85000200) is NOT a T3 event",
        not fm.matches_t3(ev),
    )


# ---------------------------------------------------------------------
# Sept 6/7, 2026 — real overnight Comcast instability episode reported by
# the user: a T3 burst at 21:38:50-21:40:21 CDT (09-06), both known ID
# variants present, discovered *not* counted by the production poller's
# actual status.json 42 minutes later (well inside the 60-minute window).
#
# By the time this was investigated (the morning of 09-07), the modem's
# own finite Event Log buffer had already rolled the exact rows from that
# burst off the log — a live byte-for-byte recapture of the failing input
# was not possible, unlike the Aug 31 case. This regression case
# reconstructs the row shape from the reported real timestamps/IDs (both
# events consolidate into one row each, per the live consolidation
# behavior confirmed via a *different*, still-live burst caught during
# this same investigation — see the roadmap doc's Sept 6/7 session log)
# rather than from a captured raw XML snapshot. Re-running current code
# against it does NOT reproduce a zero count — see that session log for
# the investigation's conclusion on what was and wasn't confirmed.
# ---------------------------------------------------------------------
def test_sept6_reported_burst_is_counted_within_window():
    # Poller runs 42 minutes after the burst ends (matches the real
    # status.json generated_at the user found: 03:22:57Z vs. the burst's
    # 02:40:21Z end, both already-UTC).
    now_dt = datetime(2026, 9, 7, 3, 22, 57)
    events = [
        {
            "docsDevEvId": "82000200",
            "docsDevEvText": "No Ranging Response received - T3 time-out;",
            "docsDevEvFirstTime": "2026-09-07, 02:38:50",
            "docsDevEvLastTime": "2026-09-07, 02:39:40",
            "docsDevEvCounts": "12",
        },
        {
            "docsDevEvId": "82000500",
            "docsDevEvText": "Started Unicast Maintenance Ranging - No Response received - T3 time-out;",
            "docsDevEvFirstTime": "2026-09-07, 02:39:41",
            "docsDevEvLastTime": "2026-09-07, 02:40:21",
            "docsDevEvCounts": "8",
        },
    ]
    total, note = fm.compute_recent_t3(events, 60, now_dt)
    check(
        "Sept 6/7: reported real burst (both ID variants) counted 42min later",
        total == 20 and note is None,
        f"total={total} note={note!r}",
    )


# ---------------------------------------------------------------------
# Sept 6/7, 2026 — window-edge case, live-captured for real (not
# reconstructed): a genuine T3 burst caught mid-investigation, still
# present in the modem's log at the time. Confirmed the 60-minute window
# boundary itself is correct: an event ~57 minutes old is included, one
# ~65 minutes old (same burst family, different row) is correctly
# excluded. Locks in that the window math itself was never the problem.
# ---------------------------------------------------------------------
def test_sept7_live_window_edge_57min_in_65min_out():
    now_dt = datetime(2026, 9, 7, 7, 2, 58)
    events = [
        {
            "docsDevEvId": "82000500",
            "docsDevEvText": "Started Unicast Maintenance Ranging - No Response received - T3 time-out;",
            "docsDevEvFirstTime": "2026-09-07, 05:57:54",
            "docsDevEvLastTime": "2026-09-07, 06:06:11",  # ~56.8min old -> in
            "docsDevEvCounts": "25",
        },
        {
            "docsDevEvId": "82000200",
            "docsDevEvText": "No Ranging Response received - T3 time-out;",
            "docsDevEvFirstTime": "2026-09-07, 05:57:13",
            "docsDevEvLastTime": "2026-09-07, 05:57:13",  # ~65.75min old -> out
            "docsDevEvCounts": "1",
        },
    ]
    total, note = fm.compute_recent_t3(events, 60, now_dt)
    check(
        "Sept 7 (live): ~57min-old row counted, ~66min-old row correctly excluded",
        total == 25,
        f"total={total} note={note!r}",
    )


# ---------------------------------------------------------------------
# Sept 7, 2026 — diagnostic-note addition. A 0 count caused by "no T3
# events at all" and a 0 count caused by "T3 events exist, just all
# outside the window" were previously indistinguishable after the fact —
# exactly what made the reported Sept 6/7 incident unprovable once the
# modem's own log buffer rolled the specific rows off. Locks in that a
# genuine out-of-window match now surfaces via `note` even though the
# count itself (correctly) stays 0.
# ---------------------------------------------------------------------
def test_out_of_window_match_surfaces_diagnostic_note():
    now_dt = datetime(2026, 9, 7, 7, 9, 0)
    events = [{
        "docsDevEvId": "82000500",
        "docsDevEvText": "Started Unicast Maintenance Ranging - No Response received - T3 time-out;",
        "docsDevEvFirstTime": "2026-09-07, 05:57:54",
        "docsDevEvLastTime": "2026-09-07, 06:06:11",  # ~62.8min old -> out
        "docsDevEvCounts": "25",
    }]
    total, note = fm.compute_recent_t3(events, 60, now_dt)
    check(
        "Sept 7: 0-count with an out-of-window T3 match surfaces a diagnostic note",
        total == 0 and note is not None and "outside the window" in note,
        f"total={total} note={note!r}",
    )


# ---------------------------------------------------------------------
# Sept 7, 2026 — the actual root cause, found *after* the reconstructed
# case above shipped: not a code bug in matches_t3()/compute_recent_t3()
# at all, but the modem's own clock running ~63-67 minutes behind host
# time. Confirmed via three independent live measurements against a
# single actively-flapping burst (new rows landing seconds apart in
# modem-time across all three fetches, ruling out "it's just been
# quiet") — not measurement noise. Real rows below are copied verbatim
# from a live authenticated EventLog.asp fetch at host time
# 2026-09-07 09:55:50 CDT (the third of those three measurements); this
# is a live capture, not a reconstruction, unlike the Sept 6 case above.
# ---------------------------------------------------------------------
_SEPT7_LIVE_HOST_TIME = datetime(2026, 9, 7, 9, 55, 50)
_SEPT7_LIVE_EVENTS = [
    {  # docsDevEvIndex 2, real capture
        "docsDevEvId": "82000200",
        "docsDevEvText": "No Ranging Response received - T3 time-out;CM-MAC=78:d2:94:5c:18:80;",
        "docsDevEvFirstTime": "2026-09-07, 08:48:40",
        "docsDevEvLastTime": "2026-09-07, 08:48:40",
        "docsDevEvCounts": "1",
    },
    {  # docsDevEvIndex 4, real capture
        "docsDevEvId": "82000200",
        "docsDevEvText": "No Ranging Response received - T3 time-out;CM-MAC=78:d2:94:5c:18:80;",
        "docsDevEvFirstTime": "2026-09-07, 08:48:38",
        "docsDevEvLastTime": "2026-09-07, 08:48:38",
        "docsDevEvCounts": "1",
    },
]


def test_sept7_uncorrected_clock_skew_reproduces_the_reported_bug():
    # No clock_offset_sec (the default before this fix, and still the
    # default for any profile that doesn't set one) -> a burst that was
    # actually happening at fetch time reads as ~67min old and is
    # wrongly excluded from the 60-minute window. This IS the reported
    # bug, reproduced live.
    total, note = fm.compute_recent_t3(_SEPT7_LIVE_EVENTS, 60, _SEPT7_LIVE_HOST_TIME)
    check(
        "Sept 7 (live, uncorrected): actively-happening-right-now burst reads as 0",
        total == 0,
        f"total={total} note={note!r}",
    )


def test_sept7_corrected_clock_skew_fixes_it():
    # Same real rows, same real host time -- only difference is the
    # deployment's configured clock_offset_sec=3600 (see profiles/modem/
    # local.toml[.example]). This is what actually shipped to production
    # and was verified against this exact live burst.
    total, note = fm.compute_recent_t3(
        _SEPT7_LIVE_EVENTS, 60, _SEPT7_LIVE_HOST_TIME, clock_offset_sec=3600
    )
    check(
        "Sept 7 (live, corrected): same burst, clock_offset_sec=3600 -> counted",
        total == 2 and note is None,
        f"total={total} note={note!r}",
    )


# ---------------------------------------------------------------------
# Sept 7, 2026 (follow-up) — self-calibrating clock offset via
# DocsisStatus.asp's #Current_systemtime field, replacing the purely
# static clock_offset_sec from the fix above. `testdata_docsis_status_
# live_capture.html` is a real authenticated DocsisStatus.asp response,
# captured live at host time 2026-09-07 10:12:19 CDT (see the roadmap
# doc's "DocsisStatus.asp ToD" session log for the 3-sample verification
# this came from) — not synthesized, so this locks in the real HTML
# shape, not an assumption about it.
# ---------------------------------------------------------------------
_LIVE_DOCSIS_HTML = (Path(__file__).parent / "testdata_docsis_status_live_capture.html").read_text()


def test_parse_modem_current_time_reads_the_real_live_field():
    from bs4 import BeautifulSoup
    soup = BeautifulSoup(_LIVE_DOCSIS_HTML, "lxml")
    parsed = fm.parse_modem_current_time(soup)
    check(
        "parse_modem_current_time(): reads the real captured field correctly",
        parsed == datetime(2026, 9, 7, 9, 11, 33),
        f"parsed={parsed}",
    )


def test_resolve_clock_offset_sec_prefers_live_measurement():
    # Real host time at the moment of this exact capture (see docstring
    # above) vs. the real modem_reported_now parsed from it -> the ~60min
    # skew this whole investigation was chasing, measured directly rather
    # than inferred from event freshness.
    modem_reported_now = datetime(2026, 9, 7, 9, 11, 33)
    now_dt = datetime(2026, 9, 7, 10, 12, 19)
    offset_sec, note = fm.resolve_clock_offset_sec(modem_reported_now, now_dt, configured_offset_sec=3600)
    check(
        "resolve_clock_offset_sec(): live measurement used, no fallback note",
        note is None and abs(offset_sec - 3646) < 1,
        f"offset_sec={offset_sec} note={note!r}",
    )


def test_resolve_clock_offset_sec_falls_back_when_field_missing():
    now_dt = datetime(2026, 9, 7, 10, 12, 19)
    offset_sec, note = fm.resolve_clock_offset_sec(None, now_dt, configured_offset_sec=3600)
    check(
        "resolve_clock_offset_sec(): missing field falls back to configured value, with a note",
        offset_sec == 3600 and note is not None and "unavailable" in note,
        f"offset_sec={offset_sec} note={note!r}",
    )


def test_resolve_clock_offset_sec_rejects_insane_live_reading():
    # e.g. a modem that just rebooted with its clock not yet synced
    # (reporting something like 1970) shouldn't be trusted just because
    # the field parsed successfully.
    modem_reported_now = datetime(1970, 1, 1, 0, 0, 0)
    now_dt = datetime(2026, 9, 7, 10, 12, 19)
    offset_sec, note = fm.resolve_clock_offset_sec(modem_reported_now, now_dt, configured_offset_sec=3600)
    check(
        "resolve_clock_offset_sec(): wildly-off live reading rejected, falls back",
        offset_sec == 3600 and note is not None and "sanity bound" in note,
        f"offset_sec={offset_sec} note={note!r}",
    )


def test_end_to_end_real_capture_self_calibrates_and_counts_correctly():
    # The actual bug, fixed the actual way it ships: parse the real
    # captured DocsisStatus.asp for modem_reported_now, resolve the live
    # offset against it (no configured value needed at all here), then
    # feed that into compute_recent_t3() against the real captured
    # EventLog.asp burst from the earlier fix. No hardcoded 3600 anywhere
    # in this test — it's derived exactly the way main() derives it.
    from bs4 import BeautifulSoup
    soup = BeautifulSoup(_LIVE_DOCSIS_HTML, "lxml")
    modem_reported_now = fm.parse_modem_current_time(soup)
    now_dt = datetime(2026, 9, 7, 10, 12, 19)  # real host time of this capture
    offset_sec, offset_note = fm.resolve_clock_offset_sec(modem_reported_now, now_dt, configured_offset_sec=0)
    total, note = fm.compute_recent_t3(_SEPT7_LIVE_EVENTS, 60, now_dt, offset_sec)
    check(
        "End-to-end: self-calibrated offset (no static config) correctly counts the real burst",
        offset_note is None and total == 2 and note is None,
        f"offset_sec={offset_sec} offset_note={offset_note!r} total={total} note={note!r}",
    )


if __name__ == "__main__":
    test_unparseable_lasttime_falls_back_to_firsttime()
    test_both_timestamps_unparseable_excluded_with_note()
    test_82000500_id_variant_matches()
    test_ucd_invalid_alone_not_counted_as_t3()
    test_sept6_reported_burst_is_counted_within_window()
    test_sept7_live_window_edge_57min_in_65min_out()
    test_out_of_window_match_surfaces_diagnostic_note()
    test_sept7_uncorrected_clock_skew_reproduces_the_reported_bug()
    test_sept7_corrected_clock_skew_fixes_it()
    test_parse_modem_current_time_reads_the_real_live_field()
    test_resolve_clock_offset_sec_prefers_live_measurement()
    test_resolve_clock_offset_sec_falls_back_when_field_missing()
    test_resolve_clock_offset_sec_rejects_insane_live_reading()
    test_end_to_end_real_capture_self_calibrates_and_counts_correctly()

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s): {FAILURES}")
        sys.exit(1)
    print("\nAll regression cases pass.")
