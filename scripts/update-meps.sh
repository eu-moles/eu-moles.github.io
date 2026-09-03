#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository_root/src"
source "$repository_root/scripts/lib/data-utils.sh"

progress 0 2 "MEP directory: checking cache"
if [[ ! -f data/meps.xml ]] || (( $(date +%s) - $(stat -c %Y data/meps.xml) > $((24 * 60 * 60)) )); then
  progress 1 2 "MEP directory: downloading latest list"
  wget -qO data/meps.xml https://www.europarl.europa.eu/meps/en/full-list/xml
else
  progress 1 2 "MEP directory: using cached list"
fi
format_xml data/meps.xml
progress 2 2 "MEP directory: formatted"
