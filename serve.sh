#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/src"
exec hugo server -D -b http://localhost:1313/ -M --noBuildLock
