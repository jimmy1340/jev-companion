#!/bin/bash
# Tests use synthetic fixtures only: no WeChat read, Keychain access, or network request.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$PROJECT_DIR/build.sh" --test-only
