#!/usr/bin/env bash
# providers/vpn/fetch_vpn.sh
# Core VPN provider (PIA WireGuard). Local-only — no SSH target, no gate,
# unlike the pfsense-family providers. Polls piactl (PIA app state) and
# wg (WireGuard kernel module) directly on this host and writes
# shared/vpn/{profile}/vpn.json.
#
# Field sourcing (see docs/network-providers-roadmap.md, "Data Sources —
# Resolved"): connectionstate/region/protocol/vpnip come from piactl;
# interface/latest_handshake/transfer come from `wg show <iface> dump`;
# killswitch comes from PIA's policy routing table, independent of both;
# killswitch_mode comes from PIA's own settings.json (world-readable, no
# piactl support and no sudo needed — see "Killswitch Mode" below);
# tunnel_latency_ms comes from a single ICMP echo sent through the tunnel
# interface itself (see the "Tunnel latency" block below) — there is no
# pre-computed source for this: piactl exposes no latency/ping subcommand,
# and PIA's own per-region LatencyTracker (used for its GUI region picker)
# is internal daemon RPC state, not reachable via piactl or a readable
# file. Confirmed live during discovery, not assumed from docs.
#
# `wg show` requires root. This script calls it via a narrowly-scoped
# passwordless sudoers rule (/etc/sudoers.d/gtex62-core-vpn) for exactly
# `wg show wgpia0 dump` — nothing else is authorized. If the profile's
# [interface].name is changed away from wgpia0, that sudo call will start
# failing until the sudoers rule is updated to match; this is intentional
# scope, not a bug.
set -euo pipefail

PROFILE_ID="${1:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/vpn/${PROFILE_ID}.toml"
OUT_DIR="$CACHE_ROOT/shared/vpn/${PROFILE_ID}"
VPN_JSON="$OUT_DIR/vpn.json"
TMP_DIR="$CACHE_ROOT/tmp"
mkdir -p "$OUT_DIR" "$TMP_DIR"

parse_root_value() {
  local path="$1"
  local key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '
    /^[[:space:]]*\[/ { if (in_section) exit; next }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }
  ' "$path"
}

parse_section_value() {
  local path="$1"
  local section="$2"
  local key="$3"
  [[ -f "$path" ]] || return 0
  awk -F= -v section="$section" -v key="$key" '
    /^[[:space:]]*\[/ {
      in_section = ($0 == "[" section "]")
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }
  ' "$path"
}

write_status() {
  local state="$1"
  local note="$2"
  jq -n \
    --arg state       "$state" \
    --arg profile     "$PROFILE_ID" \
    --arg collector   "vpn" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note        "$note" \
    '{state:$state,profile:$profile,collector:$collector,generated_at:$generated_at,note:$note}' > "$VPN_JSON"
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

if [[ ! -f "$PROFILE_TOML" ]]; then
  write_status "error" "missing profile toml"
  exit 0
fi

ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
if [[ "${ENABLED:-true}" != "true" ]]; then
  write_status "disabled" "profile disabled"
  exit 0
fi

IFACE="$(parse_section_value "$PROFILE_TOML" interface name || true)"
IFACE="${IFACE:-wgpia0}"

# -------------------------------------------------------------------------
# Cache TTL
# -------------------------------------------------------------------------

CACHE_TTL="$(parse_root_value "$PROFILE_TOML" cache_ttl_sec || true)"
CACHE_TTL="${CACHE_TTL:-10}"

if [[ -f "$VPN_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$VPN_JSON" 2>/dev/null || echo 0)"
  age=$(( now_ts - file_ts ))
  if [[ "$age" -lt "$CACHE_TTL" ]]; then
    exit 0
  fi
fi

# -------------------------------------------------------------------------
# piactl collection (PIA-application facts)
# -------------------------------------------------------------------------

if ! command -v piactl >/dev/null 2>&1; then
  write_status "error" "piactl not found"
  exit 0
fi

CONNECTIONSTATE="$(piactl get connectionstate 2>/dev/null || true)"
REGION="$(piactl get region 2>/dev/null || true)"
PROTOCOL="$(piactl get protocol 2>/dev/null || true)"
VPNIP="$(piactl get vpnip 2>/dev/null || true)"
PROTOCOL="${PROTOCOL:-wireguard}"

# -------------------------------------------------------------------------
# wg dump collection (WireGuard kernel-module facts) — best-effort.
# A failure here (e.g. sudoers rule missing) degrades handshake/transfer
# fields to null rather than failing the whole fetch; killswitch below is
# independent of this and still gets computed.
# -------------------------------------------------------------------------

WG_RAW="$TMP_DIR/vpn_wg_${PROFILE_ID}_$$.txt"
WG_NOTE=""
if command -v wg >/dev/null 2>&1; then
  # shellcheck disable=SC2024  # $WG_RAW is a user-owned tmp file, not a
  # privileged target — only the `wg` read needs sudo, not this write.
  if ! sudo -n wg show "$IFACE" dump > "$WG_RAW" 2>/dev/null; then
    WG_NOTE="sudo wg dump failed (check /etc/sudoers.d/gtex62-core-vpn)"
    : > "$WG_RAW"
  fi
else
  WG_NOTE="wg not found"
  : > "$WG_RAW"
fi

# -------------------------------------------------------------------------
# Tunnel latency — single ICMP echo through the tunnel interface, to a
# public target (NOT the VPN endpoint IP: confirmed live that PIA excludes
# the endpoint's own IP from the tunnel's routes, so pinging it via -I
# silently takes the same physical path as an untunneled ping and just
# re-measures the WAN link, not the tunnel). 1.1.1.1 matches the standing
# ping targets already used elsewhere in this codebase (fetch_net.sh,
# fetch_connectivity.sh). No sudo needed — ping carries cap_net_raw=ep.
# Best-effort like the wg dump above: failure (interface down/missing,
# no reply) degrades the field to null rather than failing the whole
# fetch.
# -------------------------------------------------------------------------

PING_TARGET="1.1.1.1"
TUNNEL_LATENCY_MS=""
PING_NOTE=""
if command -v ping >/dev/null 2>&1; then
  if ping_out="$(ping -I "$IFACE" -c1 -W1 "$PING_TARGET" 2>&1)"; then
    TUNNEL_LATENCY_MS="$(printf '%s' "$ping_out" | grep -o 'time=[0-9.]*' | head -n1 | cut -d= -f2)"
    [[ -z "$TUNNEL_LATENCY_MS" ]] && PING_NOTE="tunnel ping produced no time= (unexpected ping output)"
  else
    PING_NOTE="tunnel ping to $PING_TARGET via $IFACE failed"
  fi
else
  PING_NOTE="ping not found"
fi

# -------------------------------------------------------------------------
# Killswitch — PIA policy routing table, read-only, no sudo required.
# Independent of the wg dump above. Only re-derived while Connected; outside
# that, held at its previous value (see docs/network-providers-roadmap.md,
# "Killswitch Detection — Verified Mechanism": a voluntary disconnect clears
# this table by design, making an empty table indistinguishable from
# "killswitch off" by inspection alone).
# -------------------------------------------------------------------------

PREV_KILLSWITCH="false"
if [[ -f "$VPN_JSON" ]]; then
  PREV_KILLSWITCH="$(jq -r '.killswitch // false' "$VPN_JSON" 2>/dev/null || echo false)"
fi

export VPN_ROUTE_TABLE
VPN_ROUTE_TABLE="$(ip route show table piavpnFwdrt 2>/dev/null || true)"

# -------------------------------------------------------------------------
# Killswitch mode — PIA's own settings.json, read-only, no sudo required.
# Distinct from (and independent of) the route-table enforcement check
# above: `killswitch` there answers "is it blocking traffic right now";
# this answers "which mode is configured" (regular vs Advanced Kill
# Switch) — a question the route table cannot answer on its own (see
# docs/network-providers-roadmap.md, "Killswitch Detection — Verified
# Mechanism": while Connected, both modes produce an identical
# `dev <iface>` + `blackhole` table; they only diverge at/after a
# voluntary disconnect, a moment fetch_vpn.sh deliberately doesn't
# re-derive `killswitch` from, per the carry-forward logic above).
#
# `piactl get`/`set` have no `killswitch` type at all (confirmed via
# `piactl --help`'s own type lists — not just trial-and-error). The
# daemon persists the setting as a plain tri-state string field in
# /opt/piavpn/etc/settings.json ("off" | "auto" | "on"), confirmed
# live from the strings embedded in the PIA client binary itself:
# "auto" is the regular "VPN Kill Switch", "on" is "Advanced Kill
# Switch" (which the client's own UI states always implies regular KS
# too). That file is world-readable (mode 644, root:piavpn, under 755
# dirs) — no sudoers rule needed, unlike the wg dump above.
# -------------------------------------------------------------------------

PIA_SETTINGS_JSON="${GTEX62_PIA_SETTINGS_JSON:-/opt/piavpn/etc/settings.json}"
KILLSWITCH_MODE_RAW=""
KILLSWITCH_MODE_NOTE=""
if [[ -r "$PIA_SETTINGS_JSON" ]]; then
  KILLSWITCH_MODE_RAW="$(jq -r '.killswitch // empty' "$PIA_SETTINGS_JSON" 2>/dev/null || true)"
  [[ -z "$KILLSWITCH_MODE_RAW" ]] && KILLSWITCH_MODE_NOTE="PIA settings.json had no killswitch key"
else
  KILLSWITCH_MODE_NOTE="PIA settings.json not readable ($PIA_SETTINGS_JSON)"
fi

# -------------------------------------------------------------------------
# Build vpn.json
# -------------------------------------------------------------------------

python3 - "$WG_RAW" "$VPN_JSON" \
  "$PROFILE_ID" "$CONNECTIONSTATE" "$REGION" "$PROTOCOL" "$VPNIP" \
  "$IFACE" "$WG_NOTE" "$PREV_KILLSWITCH" \
  "$TUNNEL_LATENCY_MS" "$PING_NOTE" \
  "$KILLSWITCH_MODE_RAW" "$KILLSWITCH_MODE_NOTE" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, sys, time

(wg_raw_path, out_path, profile_id, connectionstate, region, protocol, vpnip,
 iface, wg_note, prev_killswitch, tunnel_latency_ms_raw, ping_note,
 killswitch_mode_raw, killswitch_mode_note,
 generated_at) = sys.argv[1:16]

# --- wg dump parsing --------------------------------------------------
# `wg show <iface> dump` (scoped to one device) writes an interface header
# line (private-key, public-key, listen-port, fwmark) followed by one line
# per peer (public-key, preshared-key, endpoint, allowed-ips,
# latest-handshake, transfer-rx, transfer-tx, persistent-keepalive).
# PIA's tunnel has exactly one peer; take the first peer line.
endpoint = None
latest_handshake_seconds = None
keepalive_interval_seconds = None
transfer = {"rx_bytes": None, "tx_bytes": None}

try:
    with open(wg_raw_path, "r", encoding="utf-8") as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
except OSError:
    lines = []

if len(lines) >= 2:
    peer_fields = lines[1].split("\t")
    if len(peer_fields) == 8:
        _pubkey, _psk, ep, _allowed_ips, handshake_ts, rx, tx, keepalive = peer_fields
        if ep and ep != "(none)":
            endpoint = ep
        try:
            hs = int(handshake_ts)
            if hs > 0:
                latest_handshake_seconds = max(0, int(time.time()) - hs)
        except ValueError:
            pass
        try:
            transfer["rx_bytes"] = int(rx)
            transfer["tx_bytes"] = int(tx)
        except ValueError:
            pass
        if keepalive not in ("off", ""):
            try:
                keepalive_interval_seconds = int(keepalive)
            except ValueError:
                pass

# --- killswitch -----------------------------------------------------------
# Verified four-state model (docs/network-providers-roadmap.md,
# "Killswitch Detection — Verified Mechanism"):
#   dev <iface> + blackhole  -> Connected, Kill Switch enabled
#   dev <iface> only         -> Connected, Kill Switch disabled
#   blackhole only           -> tunnel failed, Kill Switch enforcing
#   empty                    -> voluntary disconnect, not enforced by design
# Only re-derived while Connected; empty table while Connected is treated as
# a transient read race and held at the previous value, same as any other
# non-Connected state — an empty table is otherwise indistinguishable from
# killswitch-off by inspection alone.
route_table = os.environ.get("VPN_ROUTE_TABLE", "")
prev_ks_bool = str(prev_killswitch).strip().lower() == "true"

if connectionstate == "Connected" and route_table.strip():
    killswitch = "blackhole" in route_table
else:
    killswitch = prev_ks_bool

# --- killswitch mode --------------------------------------------------
# Configured mode, not enforcement state (see "Killswitch mode" block in
# the shell script above) — read fresh every run regardless of
# connectionstate, since it's a persisted setting, not something derived
# from live routing. Only the three values PIA's own client emits are
# trusted; anything else (unreadable file, unexpected value from a PIA
# version this wasn't verified against) degrades to null with a note
# rather than guessing.
VALID_KILLSWITCH_MODES = ("off", "auto", "on")
if killswitch_mode_raw in VALID_KILLSWITCH_MODES:
    killswitch_mode = killswitch_mode_raw
else:
    killswitch_mode = None
    if not killswitch_mode_note and killswitch_mode_raw:
        killswitch_mode_note = f"unrecognized PIA killswitch value: {killswitch_mode_raw!r}"

# --- health classification -------------------------------------------------
# Rebased off WireGuard's own protocol constants, not the keepalive
# interval (see docs/network-providers-roadmap.md, "Health Classification
# (VPN)"). The original 60s/180s split assumed handshake age tracks the
# 25s PersistentKeepalive cadence ("never miss more than one or two
# keepalive cycles") — live capture during this session (72 samples over
# 6 minutes, 5s poll of `wg show wgpia0 dump`) disproved that: keepalive
# sends stayed on their own 25s schedule throughout, while the handshake
# timestamp itself only advanced three times, at exactly +120s each,
# regardless of keepalive traffic. That's WireGuard's REKEY-AFTER-TIME
# (a session renegotiates once it's 120s old) — a mechanism completely
# decoupled from PersistentKeepalive. REJECT-AFTER-TIME (180s: no
# successful handshake within this and the session is protocol-dead) was
# already correct and is unchanged.
#
# HEALTHY_THRESHOLD_SEC = 130: the observed capture's per-cycle max age
# just before rollover was 118-120s (three cycles, each rolling at
# exactly +120s) — 130s keeps HEALTHY covering the entire normal rekey
# cycle with a 10s margin above the highest age actually observed, so it
# doesn't false-negative against real rekey timing jitter.
HEALTHY_THRESHOLD_SEC = 130
DEAD_THRESHOLD_SEC = 180

if connectionstate != "Connected" or latest_handshake_seconds is None or latest_handshake_seconds > DEAD_THRESHOLD_SEC:
    health = "DEAD"
elif latest_handshake_seconds < HEALTHY_THRESHOLD_SEC:
    health = "HEALTHY"
else:
    health = "STALE"

# --- tunnel latency ---------------------------------------------------
try:
    tunnel_latency_ms = float(tunnel_latency_ms_raw) if tunnel_latency_ms_raw else None
except ValueError:
    tunnel_latency_ms = None

# --- assemble payload -------------------------------------------------
note_parts = [p for p in (wg_note, ping_note, killswitch_mode_note) if p]
payload = {
    "state":        "ok",
    "profile":      profile_id,
    "collector":    "vpn",
    "generated_at": generated_at,
    "note":         "; ".join(note_parts),
    "connectionstate":             connectionstate or None,
    "region":                      region or None,
    "protocol":                    protocol or None,
    "interface":                   iface,
    "vpnip":                       vpnip or None,
    "endpoint":                    endpoint,
    "latest_handshake_seconds":    latest_handshake_seconds,
    "keepalive_interval_seconds":  keepalive_interval_seconds,
    "transfer":                    transfer,
    "tunnel_latency_ms":           tunnel_latency_ms,
    "killswitch":                  killswitch,
    "killswitch_mode":             killswitch_mode,
    "health":                      health,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY

rm -f "$WG_RAW"
