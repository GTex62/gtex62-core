#!/usr/bin/env bash
# Runs the airgradient provider, advisor, Doctor-row and HA-export tests. Nothing real is touched: the provider test uses
# a fake device on localhost and a temporary config/cache tree. Usage: tests/airgradient/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in test_advisor.py test_fetch_airgradient.py test_doctor_row.py test_ha_export.py; do
  echo "== $t"
  python3 "$HERE/$t" || rc=1
done
find "$HERE/.." "$HERE/../../providers/airgradient" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
exit $rc
