#!/usr/bin/env bash
# providers/modem/fetch_modem.sh
# Core modem provider (Netgear CM1000 cable modem admin UI, HTTP scrape via
# pfSense's NAT-to-VIP path). Thin wrapper — same shape as fetch_github.sh —
# since the auth/HTML/XML parsing logic lives in fetch_modem.py rather than
# the bash+awk TOML-helper style used by fetch_pfsense.sh/fetch_vpn.sh.
# See docs/network-providers-roadmap.md, "Modem-Level Corroboration Provider".
set -euo pipefail

PROFILE_ID="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/fetch_modem.py" "$PROFILE_ID"
