#!/usr/bin/env bash
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "$CORE_DIR/bin/gtex62-core-bootstrap-runtime" "$@"
