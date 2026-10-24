#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
python3 -m venv .local/test-venv
.local/test-venv/bin/python -m pip install -q -r tests/requirements.txt
if [[ "${1:-}" == "--aot" ]]; then
  APP_VERSION="$(sed -n 's/^version: \([^+]*\).*/\1/p' client/pubspec.yaml)"
  export CODEXLINK_TEST_COMMAND="${CODEXLINK_TEST_COMMAND:-$ROOT_DIR/.local/release-v$APP_VERSION/linux-musl-x64/CodexLink.Server}"
else
  dotnet build server/CodexLink.Server -c Release
fi
.local/test-venv/bin/python -m unittest discover -s tests -v
