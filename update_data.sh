#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/src"

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

fetch_language_xml() {
  local url="$1"
  local destination="$2"
  local temporary
  local formatted

  temporary=$(mktemp "${destination}.tmp.XXXXXX")
  formatted=$(mktemp "${destination}.formatted.XXXXXX")
  if curl -fsSL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 1 \
    -H 'Accept: application/rdf+xml' \
    -H 'User-Agent: EU-Moles-data-updater-1.0' \
    --output "$temporary" "$url" &&
    grep -q '<rdf:RDF' "$temporary" &&
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

translate_to_english() {
  local source_language="$1"
  local source_text="$2"

  curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 \
    -G 'https://translate.googleapis.com/translate_a/single' \
    --data-urlencode 'client=gtx' \
    --data-urlencode "sl=$source_language" \
    --data-urlencode 'tl=en' \
    --data-urlencode 'dt=t' \
    --data-urlencode "q=$source_text" |
    jq -er '[.[0][]? | .[0]?] | join("")'
}

find_hugo() {
  if [[ -n "${HUGO_BIN:-}" && -x "$HUGO_BIN" ]]; then
    printf '%s\n' "$HUGO_BIN"
    return
  fi

  if command -v hugo > /dev/null 2>&1; then
    command -v hugo
    return
  fi

  if [[ -x /home/linuxbrew/.linuxbrew/bin/hugo ]]; then
    printf '%s\n' /home/linuxbrew/.linuxbrew/bin/hugo
    return
  fi

  return 1
}

cache_transcript_translations() {
  local voting_date="$1"
  local directory="$2"
  local hugo_bin
  local temporary_site
  local motions_file
  local speeches_file
  local translations_file="$directory/translations.json"
  local candidate
  local speech_number
  local source_language
  local source_text
  local translated_text
  local translations_temporary
  local candidates_file

  hugo_bin=$(find_hugo) || {
    echo "Hugo was not found; skipping cached transcript translations for $voting_date." >&2
    return
  }

  temporary_site=$(mktemp -d "${TMPDIR:-/tmp}/eu-moles-translations.XXXXXX")
  if ! "$hugo_bin" --destination "$temporary_site" --noBuildLock --quiet; then
    rm -rf "$temporary_site"
    echo "Could not build the temporary transcript catalogue; skipping cached translations for $voting_date." >&2
    return
  fi
  motions_file="$temporary_site/motions/index.json"
  speeches_file="$temporary_site/speeches/index.json"
  if [[ ! -s "$motions_file" || ! -s "$speeches_file" ]]; then
    rm -rf "$temporary_site"
    echo "No transcript catalogue was generated; skipping cached translations for $voting_date." >&2
    return
  fi

  if [[ ! -s "$translations_file" ]]; then
    translations_temporary=$(mktemp "${translations_file}.tmp.XXXXXX")
    jq -n '{version: 1, translations: {}}' > "$translations_temporary"
    mv "$translations_temporary" "$translations_file"
  fi

  candidates_file=$(mktemp "${TMPDIR:-/tmp}/eu-moles-translation-candidates.XXXXXX")
  jq -cn --arg date "$voting_date" --slurpfile motions "$motions_file" --slurpfile speeches "$speeches_file" '
    [
      $motions[0][]
      | select(.date == $date)
      | .discussion[]?
      | select(.language and .language.code and .speechNumber and .text)
      | {
          speechNumber: (.speechNumber | tostring),
          sourceLanguage: (.language.code | ascii_downcase),
          sourceText: .text
        }
    ] + [
      $speeches[0][]
      | select(.date == $date and .language and .language.code and .speechNumber and .text)
      | {
          speechNumber: (.speechNumber | tostring),
          sourceLanguage: (.language.code | ascii_downcase),
          sourceText: .text
        }
    ]
    | unique_by(.speechNumber)
    | .[]
  ' > "$candidates_file"

  # The generated catalogues define the speech records we retain: motion
  # discussions and the one-minute-speeches agenda item. Drop older, broader
  # context extractions from the translation cache.
  translations_temporary=$(mktemp "${translations_file}.tmp.XXXXXX")
  if ! jq --slurpfile candidates "$candidates_file" '
      .translations |= with_entries(
        select(.key as $speech_number | $candidates | any(.speechNumber == $speech_number))
      )
    ' "$translations_file" > "$translations_temporary"; then
    rm -f "$translations_temporary" "$candidates_file"
    rm -rf "$temporary_site"
    return 1
  fi
  mv "$translations_temporary" "$translations_file"

  while IFS= read -r candidate; do
    speech_number=$(jq -r '.speechNumber' <<< "$candidate")
    source_language=$(jq -r '.sourceLanguage' <<< "$candidate")
    source_text=$(jq -r '.sourceText' <<< "$candidate")

    if jq -e \
      --arg speech_number "$speech_number" \
      --arg source_language "$source_language" \
      --arg source_text "$source_text" \
      '.translations[$speech_number] | select(
        .sourceLanguage == $source_language and
        .sourceText == $source_text and
        (.englishText | type) == "string" and
        (.englishText | length) > 0
      )' "$translations_file" > /dev/null; then
      continue
    fi

    if (( ${#source_text} > 15000 )); then
      echo "Skipping $speech_number: contribution exceeds the translation service limit." >&2
      continue
    fi

    echo "Translating $speech_number ($source_language)…"
    if translated_text=$(translate_to_english "$source_language" "$source_text"); then
      translations_temporary=$(mktemp "${translations_file}.tmp.XXXXXX")
      jq \
        --arg speech_number "$speech_number" \
        --arg source_language "$source_language" \
        --arg source_text "$source_text" \
        --arg translated_text "$translated_text" \
        '.translations[$speech_number] = {
          sourceLanguage: $source_language,
          sourceText: $source_text,
          englishText: $translated_text
        }' "$translations_file" > "$translations_temporary"
      mv "$translations_temporary" "$translations_file"
    else
      echo "Translation failed for $speech_number; it will be retried on the next update." >&2
    fi

    # Avoid rapid bursts to the third-party translation endpoint.
    sleep 0.5
  done < "$candidates_file"

  rm -f "$candidates_file"
  rm -rf "$temporary_site"
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

  mkdir -p data/languages
  while IFS= read -r language_uri; do
    language_code="${language_uri##*/}"
    language_file="data/languages/${language_code}.xml"
    [[ -s "$language_file" ]] || fetch_language_xml "$language_uri" "$language_file"
  done < <(jq -r '.data[] | .recorded_in_a_realization_of[]? | .originalLanguage[]?' "$dir/speeches.json" | sort -u)

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
  cache_transcript_translations "$voting_date" "$dir"
  format_data_sources "$dir"
  break
done
