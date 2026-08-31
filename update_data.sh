#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/src"

make_temporary_file() {
  local purpose="$1"

  mktemp "${TMPDIR:-/tmp}/eu-moles-${purpose}.XXXXXX"
}

format_json() {
  local file="$1"
  local temporary

  temporary=$(make_temporary_file "format-json")
  jq '.' "$file" > "$temporary"
  mv "$temporary" "$file"
}

format_xml() {
  local file="$1"
  local temporary

  temporary=$(make_temporary_file "format-xml")
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

curl_with_error_url() {
  local error_log
  local status
  local url="${!#}"

  error_log=$(make_temporary_file "curl-error")
  if curl --stderr "$error_log" "$@"; then
    status=0
  else
    status=$?
  fi

  cat "$error_log" >&2
  if grep -q '^curl: (' "$error_log"; then
    printf 'curl request URL: %s\n' "$url" >&2
  fi
  rm -f "$error_log"
  return "$status"
}

cutoff_date=$(date -d '1 month ago' +%F)
voting_dates=$(curl_with_error_url -fsSL "https://data.europarl.europa.eu/distribution/meetings_$(date +%Y)_4_en.csv" |
  sed -nE 's/^MTG-PL-([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' |
  sort -u)
api="https://data.europarl.europa.eu/api/v2"

fetch_json() {
  local url="$1"
  local destination="$2"
  local temporary
  local formatted

  temporary=$(make_temporary_file "fetch-json")
  formatted=$(make_temporary_file "format-json")
  if curl_with_error_url -fsSL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 1 \
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

  temporary=$(make_temporary_file "fetch-xml")
  formatted=$(make_temporary_file "format-xml")
  if curl_with_error_url -fsSL --output "$temporary" "$url" &&
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

  temporary=$(make_temporary_file "fetch-language")
  formatted=$(make_temporary_file "format-language")
  if curl_with_error_url -fsSL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 1 \
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

  archive=$(make_temporary_file "transcript-docx")
  document_xml=$(make_temporary_file "transcript-xml")
  formatted=$(make_temporary_file "format-transcript")
  if curl_with_error_url -fsSL --output "$archive" "$url" &&
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

fetch_oeil_procedure() {
  local reference="$1"
  local destination="$2"
  local temporary

  temporary=$(make_temporary_file "fetch-oeil")
  if curl_with_error_url -fsSL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 1 \
    -G --data-urlencode "reference=$reference" \
    -H 'User-Agent: EU-Moles-data-updater-1.0' \
    --output "$temporary" \
    'https://oeil.europarl.europa.eu/oeil/en/procedure-file' &&
    grep -q '<title>Procedure File:' "$temporary"; then
    mv "$temporary" "$destination"
  else
    rm -f "$temporary"
    return 1
  fi
}

extract_oeil_document_summaries() {
  local source_directory="$1"
  local destination="$2"
  local rows
  local temporary
  local procedure_file
  local procedure_id

  rows=$(make_temporary_file "oeil-summary-rows")
  temporary=$(make_temporary_file "oeil-summary")

  while IFS= read -r -d '' procedure_file; do
    procedure_id=${procedure_file##*/}
    procedure_id=${procedure_id%.html}
    awk -v procedure_id="$procedure_id" '
      function emit() {
        if (document_id != "" && summary_id != "") {
          printf "%s\t%s\t%s\n", procedure_id, document_id, summary_id
        }
        document_id = ""
        summary_id = ""
      }
      /<tr[[:space:]>]/ {
        emit()
        in_row = 1
      }
      in_row && match($0, /https:\/\/www\.europarl\.europa\.eu\/doceo\/document\/[A-Z0-9-]+_EN\.(html|pdf)/) {
        document_id = substr($0, RSTART, RLENGTH)
        sub(/^.*\/document\//, "", document_id)
        sub(/_EN\.(html|pdf)$/, "", document_id)
      }
      in_row && match($0, /document-summary\?id=[0-9]+/) {
        summary_id = substr($0, RSTART, RLENGTH)
        sub(/^.*id=/, "", summary_id)
      }
      /<\/tr>/ {
        emit()
        in_row = 0
      }
      END { emit() }
    ' "$procedure_file" >> "$rows"
  done < <(find "$source_directory" -maxdepth 1 -type f -name '*.html' -print0 | sort -z)

  jq -Rn '
    reduce inputs as $line (
      {version: 1, procedures: {}};
      ($line | split("\t")) as $fields
      | select($fields | length == 3)
      | .procedures[$fields[0]] = (
          (.procedures[$fields[0]] // {}) + {
            ($fields[1]): {
              id: $fields[2],
              url: ("https://oeil.europarl.europa.eu/oeil/en/document-summary?id=" + $fields[2])
            }
          }
        )
    )
  ' "$rows" > "$temporary"
  mv "$temporary" "$destination"
  rm -f "$rows"
}

translate_to_english() {
  local source_language="$1"
  local source_text="$2"

  curl_with_error_url -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 \
    -G 'https://translate.googleapis.com/translate_a/single' \
    --data-urlencode 'client=gtx' \
    --data-urlencode "sl=$source_language" \
    --data-urlencode 'tl=en' \
    --data-urlencode 'dt=t' \
    --data-urlencode "q=$source_text" |
    jq -er '[.[0][]? | .[0]?] | join("")'
}

split_translation_text() {
  local source_text="$1"
  local limit="$2"
  local chunks_directory="$3"
  local source_file="$chunks_directory/source.txt"

  printf '%s' "$source_text" > "$source_file"
  awk -v limit="$limit" -v output_directory="$chunks_directory" '
    function abs(value) { return value < 0 ? -value : value }
    function ceil(value) { return int(value) + (value > int(value)) }
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function write_chunk(value,    file) {
      value = trim(value)
      if (value == "") return
      file = sprintf("%s/part-%03d.txt", output_directory, ++chunk_count)
      printf "%s", value > file
      close(file)
    }
    {
      text = text (NR == 1 ? "" : "\n") $0
    }
    END {
      total = length(text)
      requests = ceil(total / limit)
      start = 1

      for (request = 1; request <= requests && start <= total; request++) {
        remaining = total - start + 1
        remaining_requests = requests - request + 1
        if (remaining_requests == 1) {
          write_chunk(substr(text, start))
          break
        }

        target = ceil(remaining / remaining_requests)
        minimum = remaining - (limit * (remaining_requests - 1))
        if (minimum < 1) minimum = 1
        maximum = limit
        if (maximum > remaining) maximum = remaining
        cut = 0
        best_score = -1

        # Prefer a paragraph boundary nearest to an even share of the text.
        for (i = minimum + 1; i <= maximum; i++) {
          if (substr(text, start + i - 2, 2) == "\n\n") {
            candidate = i - 1
            score = abs(candidate - target)
            if (best_score < 0 || score < best_score) {
              cut = candidate
              best_score = score
            }
          }
        }

        # A sentence boundary is the next-best option for an oversized paragraph.
        if (cut == 0) {
          for (i = minimum; i <= maximum; i++) {
            if (substr(text, start + i - 1, 1) ~ /[.!?]/ && substr(text, start + i, 1) ~ /[[:space:]]/) {
              score = abs(i - target)
              if (best_score < 0 || score < best_score) {
                cut = i
                best_score = score
              }
            }
          }
        }

        # Never split a word unless there is no whitespace at all in the range.
        if (cut == 0) {
          for (i = minimum; i <= maximum; i++) {
            if (substr(text, start + i - 1, 1) ~ /[[:space:]]/) {
              score = abs(i - target)
              if (best_score < 0 || score < best_score) {
                cut = i
                best_score = score
              }
            }
          }
        }

        if (cut == 0) cut = target
        write_chunk(substr(text, start, cut))
        start += cut
        while (start <= total && substr(text, start, 1) ~ /[[:space:]]/) start++
      }
    }
  ' "$source_file"
}

translate_speech_to_english() {
  local source_language="$1"
  local source_text="$2"
  local limit=14000
  local chunks_directory
  local chunk_file
  local translated_part
  local translated_text=""
  local request_count=0
  local status=0

  if (( ${#source_text} <= limit )); then
    translate_to_english "$source_language" "$source_text"
    return
  fi

  chunks_directory=$(mktemp -d "${TMPDIR:-/tmp}/eu-moles-translation-chunks.XXXXXX")
  split_translation_text "$source_text" "$limit" "$chunks_directory"

  for chunk_file in "$chunks_directory"/part-*.txt; do
    [[ -f "$chunk_file" ]] || {
      status=1
      break
    }
    (( request_count > 0 )) && sleep 0.5
    if ! translated_part=$(translate_to_english "$source_language" "$(<"$chunk_file")"); then
      status=1
      break
    fi
    translated_text+="${translated_text:+$'\n\n'}${translated_part}"
    ((request_count += 1))
  done

  rm -rf "$chunks_directory"
  (( status == 0 && request_count > 0 )) || return 1
  printf '%s' "$translated_text"
}

generate_translation_candidates() {
  local directory="$1"
  local language_map
  local number
  local language_uri
  local language_file
  local language_code

  language_map=$(mktemp "${TMPDIR:-/tmp}/eu-moles-translation-languages.XXXXXX")

  # Match the language code Hugo displays from the cached EU authority files.
  while IFS=$'\t' read -r number language_uri; do
    language_file="data/languages/${language_uri##*/}.xml"
    [[ -s "$language_file" ]] || continue
    language_code=$(sed -nE 's@.*euvoc#ISO_639_1">([^<]+)</skos:notation>@\1@p' "$language_file" | head -n 1 | tr '[:upper:]' '[:lower:]')
    [[ -n "$language_code" ]] && printf '%s\t%s\n' "$number" "$language_code" >> "$language_map"
  done < <(jq -r '
    .data[]
    | .recorded_in_a_realization_of[]?
    | (.originalLanguage | map(select(. != "http://publications.europa.eu/resource/authority/language/ENG")) | first) as $source_language
    | select(.number and $source_language)
    | [.number, $source_language]
    | @tsv
  ' "$directory/speeches.json")

  # Retain every non-English parliamentary contribution from the transcript,
  # not merely speeches already used by the current motion views.
  LC_ALL=C awk -v language_map="$language_map" '
    function trim(value) {
      sub(/^[ \t\r\n\f]+/, "", value)
      sub(/[ \t\r\n\f]+$/, "", value)
      return value
    }
    function clean(value) {
      gsub(/[ \t\r\n\f]+/, " ", value)
      while (match(value, /[ \t\r\n\f]+[,.;:!?]/)) {
        value = substr(value, 1, RSTART - 1) substr(value, RSTART + RLENGTH - 1, 1) substr(value, RSTART + RLENGTH)
      }
      return trim(value)
    }
    function json_escape(value) {
      gsub(/\\/, "\\\\", value)
      gsub(/"/, "\\\"", value)
      gsub(/\n/, "\\n", value)
      gsub(/\r/, "\\r", value)
      return value
    }
    function flush_turn(    code) {
      if (!speaker || !speech_number || !buffer || !(speech_number in languages) || (speech_number in seen)) return
      code = languages[speech_number]
      printf "{\"speechNumber\":\"%s\",\"sourceLanguage\":\"%s\",\"sourceText\":\"%s\"}\n", json_escape(speech_number), json_escape(code), json_escape(buffer)
      seen[speech_number] = 1
    }
    function process_paragraph(    i,line,text,bookmark,part,without_speaker) {
      text = ""
      bookmark = ""
      for (i = 1; i <= paragraph_lines; i++) {
        line = paragraph[i]
        if (line ~ /<w:bookmarkStart/) {
          bookmark = line
          sub(/^.*w:name="/, "", bookmark)
          sub(/".*$/, "", bookmark)
        }
        if (line ~ /<w:t([[:space:]][^>]*)?>/) {
          part = line
          sub(/^.*<w:t([^>]*)>/, "", part)
          sub(/<\/w:t>.*$/, "", part)
          gsub(/&amp;/, "\\&", part)
          gsub(/&quot;/, "\\\"", part)
          gsub(/&apos;/, "\047", part)
          gsub(/&lt;/, "<", part)
          gsub(/&gt;/, ">", part)
          text = text part
        } else if (line ~ /<w:(tab|br|cr)\/>/) {
          text = text " "
        }
      }
      text = clean(text)
      if (text != "" && bookmark ~ /^_Toc/) {
        flush_turn()
        speaker = ""
        speech_number = ""
        buffer = ""
      } else if (text ~ /^[0-9]+-[0-9]+-[0-9]+$/ && bookmark != "") {
        flush_turn()
        speaker = bookmark
        sub(/^[0-9]+-[0-9]+-[0-9]+[ \t]*/, "", speaker)
        speech_number = text
        buffer = ""
      } else if (speaker != "" && text != "") {
        if (buffer == "") {
          without_speaker = text
          sub(speaker, "", without_speaker)
          if (without_speaker != text) sub(/^[^–]*–[ \t]*/, "", without_speaker)
          text = without_speaker
        }
        if (text != "") buffer = (buffer == "" ? text : buffer "\n\n" text)
      }
    }
    BEGIN {
      while ((getline line < language_map) > 0) {
        split(line, fields, "\t")
        languages[fields[1]] = fields[2]
      }
      close(language_map)
      in_paragraph = 0
      paragraph_lines = 0
    }
    /^[ \t]*<w:p>$/ {
      in_paragraph = 1
      paragraph_lines = 0
    }
    in_paragraph {
      paragraph[++paragraph_lines] = $0
    }
    /^[ \t]*<\/w:p>$/ && in_paragraph {
      process_paragraph()
      delete paragraph
      in_paragraph = 0
      paragraph_lines = 0
    }
    END { flush_turn() }
  ' "$directory/transcript.xml"

  rm -f "$language_map"
}

cache_transcript_translations() {
  local voting_date="$1"
  local directory="$2"
  local translations_file="$directory/translations.json"
  local candidate
  local speech_number
  local source_language
  local source_text
  local translated_text
  local translations_temporary
  local candidates_file

  if [[ ! -s "$translations_file" ]]; then
    translations_temporary=$(make_temporary_file "translations")
    jq -n '{version: 1, translations: {}}' > "$translations_temporary"
    mv "$translations_temporary" "$translations_file"
  fi

  candidates_file=$(mktemp "${TMPDIR:-/tmp}/eu-moles-translation-candidates.XXXXXX")
  generate_translation_candidates "$directory" > "$candidates_file"

  # The generated catalogue contains every non-English contribution that can
  # be parsed from the sitting transcript. Drop stale entries only when that
  # contribution is no longer present in the source transcript.
  translations_temporary=$(make_temporary_file "translations")
  if ! jq --slurpfile candidates "$candidates_file" '
      .translations |= with_entries(
        select(.key as $speech_number | $candidates | any(.speechNumber == $speech_number))
      )
    ' "$translations_file" > "$translations_temporary"; then
    rm -f "$translations_temporary" "$candidates_file"
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

    echo "Translating $speech_number ($source_language)…"
    if translated_text=$(translate_speech_to_english "$source_language" "$source_text"); then
      translations_temporary=$(make_temporary_file "translations")
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
}

for voting_date in $voting_dates; do
  [[ "$voting_date" == "2026-07-07" ]] || continue
  [[ "$voting_date" < "$cutoff_date" ]] || continue
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

  # Each vote result carries the procedure(s) to which it belongs.  Cache one
  # complete procedure record per distinct ID: this exposes the authoritative
  # EP document chain without making a request for every document.
  procedures_dir="$dir/procedures"
  mkdir -p "$procedures_dir"
  while IFS= read -r procedure_id; do
    procedure_file="$procedures_dir/${procedure_id}.json"
    [[ -s "$procedure_file" ]] && continue
    fetch_json "$api/procedures/$procedure_id" "$procedure_file" || {
      echo "Could not fetch procedure $procedure_id referenced by $sitting_id." >&2
      exit 1
    }
    # Stay comfortably below the public API's per-endpoint request limit.
    sleep 0.5
  done < <(jq -r '
    (
      .data[]
      | .inverse_consists_of[]?
      | objects
      | .id? // empty
      | capture("/proc/(?<id>[0-9]{4}-[0-9]{4})$").id
    ),
    (
      .data[]
      | .structuredLabel.en? // empty
      | scan("[0-9]{4}/[0-9]{4}\\([A-Z]+\\)")
      | capture("(?<year>[0-9]{4})/(?<number>[0-9]{4})\\([A-Z]+\\)")
      | "\(.year)-\(.number)"
    )
  ' "$dir/vote-results.json" | sort -u)

  # OEIL exposes document-summary IDs only on its procedure pages. Cache one
  # source page per local procedure so later processing can join each official
  # document reference to its OEIL summary without title matching.
  oeil_procedures_dir="$dir/oeil-procedures"
  mkdir -p "$oeil_procedures_dir"
  while IFS= read -r -d '' procedure_file; do
    procedure_id=${procedure_file##*/}
    procedure_id=${procedure_id%.json}
    oeil_procedure_file="$oeil_procedures_dir/${procedure_id}.html"
    [[ -s "$oeil_procedure_file" ]] && continue

    procedure_reference=$(jq -er '.data[0].label | select(test("^[0-9]{4}/[0-9]{4}\\([A-Z]+\\)$"))' "$procedure_file") || {
      echo "Could not determine the OEIL reference for procedure $procedure_id." >&2
      exit 1
    }
    fetch_oeil_procedure "$procedure_reference" "$oeil_procedure_file" || {
      echo "Could not fetch OEIL procedure page for $procedure_reference." >&2
      exit 1
    }
    sleep 0.5
  done < <(find "$procedures_dir" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
  extract_oeil_document_summaries "$oeil_procedures_dir" "$dir/oeil-document-summaries.json"

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
      if [[ ! -s "$decision_file" ]]; then
        fetch_json "$api/events/$decision_id" "$decision_file" || {
          echo "Could not fetch decision $decision_id for $sitting_id; no incomplete aggregate was saved." >&2
          exit 1
        }
        sleep 0.1
      fi
      decision_files+=("$decision_file")
    done < <(jq -r '.data[] | .consists_of[]? | split("/") | last' "$dir/vote-results.json")

    ((${#decision_files[@]})) || {
      echo "No decision IDs were supplied by $dir/vote-results.json." >&2
      exit 1
    }

    decisions_temporary=$(make_temporary_file "decisions")
    jq -s '{data: [.[].data[]]}' "${decision_files[@]}" > "$decisions_temporary"
    mv "$decisions_temporary" "$dir/decisions.json"
  fi
  cache_transcript_translations "$voting_date" "$dir"
  format_data_sources "$dir"
  break
done
