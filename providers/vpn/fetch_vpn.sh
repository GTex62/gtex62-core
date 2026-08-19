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
# killswitch comes from PIA's policy routing table, independent of both.
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
# Build vpn.json
# -------------------------------------------------------------------------

python3 - "$WG_RAW" "$VPN_JSON" \
  "$PROFILE_ID" "$CONNECTIONSTATE" "$REGION" "$PROTOCOL" "$VPNIP" \
  "$IFACE" "$WG_NOTE" "$PREV_KILLSWITCH" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, sys, time

(wg_raw_path, out_path, profile_id, connectionstate, region, protocol, vpnip,
 iface, wg_note, prev_killswitch, generated_at) = sys.argv[1:12]

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

# --- health classification -------------------------------------------------
# Verbatim from docs/network-providers-roadmap.md, "Health Classification"
# table. Hardcoded to 60/180 seconds, verified only against the current 25s
# PIA keepalive interval — revisit if keepalive_interval_seconds is ever
# observed to differ from 25. The roadmap floats scaling these thresholds by
# keepalive_interval_seconds if that happens, but gives no exact multiplier —
# that's an open item, not implemented here, so this stays exactly the
# verified 60s/180s split rather than a guess.
HEALTHY_THRESHOLD_SEC = 60
DEAD_THRESHOLD_SEC = 180

if connectionstate != "Connected" or latest_handshake_seconds is None or latest_handshake_seconds > DEAD_THRESHOLD_SEC:
    health = "DEAD"
elif latest_handshake_seconds < HEALTHY_THRESHOLD_SEC:
    health = "HEALTHY"
else:
    health = "STALE"

# --- assemble payload -------------------------------------------------
note_parts = [p for p in (wg_note,) if p]
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
    "killswitch":                  killswitch,
    "health":                      health,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY

rm -f "$WG_RAW"
