#!/bin/bash

set -euo pipefail

cd src

format_json() {
  local file="$1"
  local temporary

  temporary=$(mktemp "${file}.tmp.XXXXXX")
  jq '.' "$file" > "$temporary"
  mv "$temporary" "$file"
}

format_xml() {
  local file="$1"
  local temporary

  temporary=$(mktemp "${file}.tmp.XXXXXX")
  xmllint --format "$file" > "$temporary"
  mv "$temporary" "$file"
}

format_data_sources() {
  local directory="$1"
  local file

  while IFS= read -r -d '' file; do
    case "$file" in
      *.json) format_json "$file" ;;
      *.xml) format_xml "$file" ;;
    esac
  done < <(find "$directory" -type f \( -name '*.json' -o -name '*.xml' \) -print0)
}

if [[ ! -f data/meps.xml ]] || (( $(date +%s) - $(stat -c %Y data/meps.xml) > $((24 * 60 * 60)) )); then
  wget -qO data/meps.xml https://www.europarl.europa.eu/meps/en/full-list/xml
fi
format_xml data/meps.xml

current_date=$(date +%F)
voting_dates=$(curl -fsSL "https://data.europarl.europa.eu/distribution/meetings_$(date +%Y)_4_en.csv" |
  sed -nE 's/^MTG-PL-([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' |
  sort -u)
api="https://data.europarl.europa.eu/api/v2"

fetch_json() {
  local url="$1"
  local destination="$2"
  local temporary
  local formatted

  temporary=$(mktemp "${destination}.tmp.XXXXXX")
  formatted=$(mktemp "${destination}.formatted.XXXXXX")
  if curl -fsSL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 1 \
    -H 'Accept: application/ld+json' \
    -H 'User-Agent: EU-Moles-data-updater-1.0' \
    --output "$temporary" "$url" &&
    jq -e 'type == "object" and (.data | type == "array")' "$temporary" > /dev/null &&
    jq '.' "$temporary" > "$formatted"; then
    mv "$formatted" "$destination"
    rm -f "$temporary"
  else
    rm -f "$temporary" "$formatted"
    return 1
  fi
}

fetch_xml() {
  local url="$1"
  local destination="$2"
  local temporary
  local formatted

  temporary=$(mktemp "${destination}.tmp.XXXXXX")
  formatted=$(mktemp "${destination}.formatted.XXXXXX")
  if curl -fsSL --output "$temporary" "$url" &&
    grep -q '<PV[[:space:]>]' "$temporary" &&
    xmllint --format "$temporary" > "$formatted"; then
    mv "$formatted" "$destination"
    rm -f "$temporary"
  else
    rm -f "$temporary" "$formatted"
    return 1
  fi
}

fetch_docx_document_xml() {
  local url="$1"
  local destination="$2"
  local archive
  local document_xml
  local formatted

  archive=$(mktemp "${destination}.docx.XXXXXX")
  document_xml=$(mktemp "${destination}.xml.XXXXXX")
  formatted=$(mktemp "${destination}.formatted.XXXXXX")
  if curl -fsSL --output "$archive" "$url" &&
    unzip -p "$archive" word/document.xml > "$document_xml" &&
    grep -q '<w:document[[:space:]>]' "$document_xml" &&
    xmllint --format "$document_xml" > "$formatted"; then
    mv "$formatted" "$destination"
    rm -f "$archive" "$document_xml"
  else
    rm -f "$archive" "$document_xml" "$formatted"
    return 1
  fi
}

for voting_date in $voting_dates; do
  [[ "$voting_date" == "2026-07-06" ]] || continue
  [[ "$voting_date" < "$current_date" ]] || continue
  echo "$voting_date processing..."
  sitting_id="MTG-PL-${voting_date}"
  dir="data/votes/${voting_date}"
  mkdir -p "$dir"
  [[ -s "$dir/vote-results.json" ]] || fetch_json "$api/meetings/$sitting_id/vote-results" "$dir/vote-results.json"
  [[ -s "$dir/meeting.json" ]] || fetch_json "$api/meetings/$sitting_id" "$dir/meeting.json"
  [[ -s "$dir/activities.json" ]] || fetch_json "$api/meetings/$sitting_id/activities" "$dir/activities.json"
  [[ -s "$dir/speeches.json" ]] || fetch_json \
    "$api/speeches?sitting-date=$voting_date&activity-type=PLENARY_DEBATE_SPEECH&limit=500&sort-by=video-start-time:asc" \
    "$dir/speeches.json"

  minutes_document=$(jq -er '
    .data[0].recorded_in_a_realization_of[]
    | select(test("/PV-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    | split("/")
    | last
  ' "$dir/meeting.json")
  [[ -s "$dir/minutes.json" ]] || fetch_json "$api/plenary-session-documents/$minutes_document" "$dir/minutes.json"

  if [[ ! -s "$dir/minutes_en.xml" ]]; then
    minutes_xml_path=$(jq -er '
      .data[]
      | .is_realized_by[]
      | select(.language == "http://publications.europa.eu/resource/authority/language/ENG")
      | .is_embodied_by[]
      | select(.media_type == "https://www.iana.org/assignments/media-types/application/xml")
      | .is_exemplified_by
    ' "$dir/minutes.json")
    fetch_xml "https://data.europarl.europa.eu/$minutes_xml_path" "$dir/minutes_en.xml"
  fi

  transcript_document=$(jq -er '
    .data[0].recorded_in_a_realization_of[]
    | select(test("/CRE-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    | split("/")
    | last
  ' "$dir/meeting.json")
  [[ -s "$dir/transcript.json" ]] || fetch_json "$api/plenary-session-documents/$transcript_document" "$dir/transcript.json"

  if [[ ! -s "$dir/transcript.xml" ]]; then
    transcript_docx_path=$(jq -er '
      .data[]
      | .is_realized_by[]
      | .is_embodied_by[]
      | select(.media_type == "https://www.iana.org/assignments/media-types/application/vnd.openxmlformats-officedocument.wordprocessingml.document")
      | .is_exemplified_by
    ' "$dir/transcript.json")
    fetch_docx_document_xml "https://data.europarl.europa.eu/$transcript_docx_path" "$dir/transcript.xml"
  fi

  if [[ ! -s "$dir/decisions.json" ]]; then
    decisions_dir="$dir/decisions"
    mkdir -p "$decisions_dir"
    decision_files=()

    while IFS= read -r decision_id; do
      decision_file="$decisions_dir/${decision_id}.json"
      [[ -s "$decision_file" ]] || fetch_json "$api/events/$decision_id" "$decision_file" || {
        echo "Could not fetch decision $decision_id for $sitting_id; no incomplete aggregate was saved." >&2
        exit 1
      }
      decision_files+=("$decision_file")
    done < <(jq -r '.data[] | .consists_of[]? | split("/") | last' "$dir/vote-results.json")

    ((${#decision_files[@]})) || {
      echo "No decision IDs were supplied by $dir/vote-results.json." >&2
      exit 1
    }

    decisions_temporary=$(mktemp "$dir/decisions.json.tmp.XXXXXX")
    jq -s '{data: [.[].data[]]}' "${decision_files[@]}" > "$decisions_temporary"
    mv "$decisions_temporary" "$dir/decisions.json"
  fi
  format_data_sources "$dir"
  break
done
