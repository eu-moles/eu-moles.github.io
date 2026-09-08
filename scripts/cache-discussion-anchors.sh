#!/usr/bin/env bash
set -euo pipefail

# Cache the official CRE table-of-contents anchors. Agenda labels such as 7.1
# are not equivalent to the document anchors (for example, 7.1 is creitem8),
# because the Parliament also numbers opening, resumption, and parent items.

repository_root=$(cd "$(dirname "$0")/.." && pwd)
source "$repository_root/scripts/lib/data-utils.sh"

directory=${1:?Usage: cache-discussion-anchors.sh VOTE_DIRECTORY [TOC_HTML_FILE]}
provided_html=${2:-}
date=$(basename "$directory")
toc_html="$directory/discussion-toc.html"
anchors_file="$directory/discussion-anchors.json"

if [[ -n "$provided_html" ]]; then
  toc_html="$provided_html"
elif [[ ! -s "$toc_html" ]]; then
  temporary_html=$(make_temporary_file "discussion-toc")
  toc_url="https://www.europarl.europa.eu/doceo/document/CRE-10-${date}_EN.html"
  if ! curl_with_error_url -fsSL --connect-timeout 15 --max-time 90 --retry 2 --retry-delay 2 "$toc_url" > "$temporary_html"; then
    rm -f "$temporary_html"
    echo "Discussion anchors: could not download the official table of contents; links will open the record without an item anchor." >&2
    exit 0
  fi
  mv "$temporary_html" "$toc_html"
fi

pairs_file=$(mktemp "${TMPDIR:-/tmp}/eu-moles-discussion-anchors.XXXXXX")
sed 's/></>\n</g' "$toc_html" |
  awk '
    /<td/ && /<\/td>/ && />[[:space:]]*[0-9]+(\.[0-9]+)?\.[[:space:]]*<\/td>/ {
      item = $0
      sub(/^[^>]*>[[:space:]]*/, "", item)
      sub(/[[:space:]]*<\/td>.*$/, "", item)
      sub(/\.$/, "", item)
      agenda = item
      next
    }
    agenda != "" && /href="#creitem[0-9]+"/ {
      anchor = $0
      sub(/^.*href="#/, "", anchor)
      sub(/".*$/, "", anchor)
      print agenda "\t" anchor
      agenda = ""
    }
  ' | sort -u > "$pairs_file"

if [[ ! -s "$pairs_file" ]]; then
  rm -f "$pairs_file"
  echo "Discussion anchors: no agenda-to-anchor mappings found; links will open the record without an item anchor." >&2
  exit 0
fi

temporary_anchors=$(make_temporary_file "discussion-anchors")
jq -Rn '
  [inputs | split("\t") | select(length == 2) | {key: .[0], value: .[1]}]
  | {version: 1, anchors: from_entries}
' < "$pairs_file" > "$temporary_anchors"
mv "$temporary_anchors" "$anchors_file"
rm -f "$pairs_file"
echo "Discussion anchors: cached $(jq '.anchors | length' "$anchors_file") official agenda link(s)."
