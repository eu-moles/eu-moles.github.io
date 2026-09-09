#!/usr/bin/env bash
set -euo pipefail

if ! command -v hugo > /dev/null 2>&1; then
  echo "Error: required command 'hugo' is not available on PATH." >&2
  exit 127
fi

cd "$(dirname "$0")/src"
exec hugo --minify --gc --noBuildLock
