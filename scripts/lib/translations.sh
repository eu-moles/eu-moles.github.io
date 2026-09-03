#!/usr/bin/env bash

# Cached translation of non-English parliamentary contributions. Requires
# data-utils.sh and a working directory of src/.

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
    { text = text (NR == 1 ? "" : "\n") $0 }
    END {
      total = length(text)
      requests = ceil(total / limit)
      start = 1
      for (request = 1; request <= requests && start <= total; request++) {
        remaining = total - start + 1
        remaining_requests = requests - request + 1
        if (remaining_requests == 1) { write_chunk(substr(text, start)); break }
        target = ceil(remaining / remaining_requests)
        minimum = remaining - (limit * (remaining_requests - 1))
        if (minimum < 1) minimum = 1
        maximum = limit
        if (maximum > remaining) maximum = remaining
        cut = 0
        best_score = -1
        for (i = minimum + 1; i <= maximum; i++) {
          if (substr(text, start + i - 2, 2) == "\n\n") {
            candidate = i - 1; score = abs(candidate - target)
            if (best_score < 0 || score < best_score) { cut = candidate; best_score = score }
          }
        }
        if (cut == 0) {
          for (i = minimum; i <= maximum; i++) {
            if (substr(text, start + i - 1, 1) ~ /[.!?]/ && substr(text, start + i, 1) ~ /[[:space:]]/) {
              score = abs(i - target)
              if (best_score < 0 || score < best_score) { cut = i; best_score = score }
            }
          }
        }
        if (cut == 0) {
          for (i = minimum; i <= maximum; i++) {
            if (substr(text, start + i - 1, 1) ~ /[[:space:]]/) {
              score = abs(i - target)
              if (best_score < 0 || score < best_score) { cut = i; best_score = score }
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
  local chunks_directory chunk_file translated_part translated_text="" request_count=0 status=0

  if (( ${#source_text} <= limit )); then
    translate_to_english "$source_language" "$source_text"
    return
  fi
  chunks_directory=$(mktemp -d "${TMPDIR:-/tmp}/eu-moles-translation-chunks.XXXXXX")
  split_translation_text "$source_text" "$limit" "$chunks_directory"
  for chunk_file in "$chunks_directory"/part-*.txt; do
    [[ -f "$chunk_file" ]] || { status=1; break; }
    (( request_count > 0 )) && sleep 0.5
    if ! translated_part=$(translate_to_english "$source_language" "$(<"$chunk_file")"); then status=1; break; fi
    translated_text+="${translated_text:+$'\n\n'}${translated_part}"
    ((request_count += 1))
  done
  rm -rf "$chunks_directory"
  (( status == 0 && request_count > 0 )) || return 1
  printf '%s' "$translated_text"
}

generate_translation_candidates() {
  local directory="$1"
  local language_map number language_uri language_file language_code
  language_map=$(mktemp "${TMPDIR:-/tmp}/eu-moles-translation-languages.XXXXXX")
  while IFS=$'\t' read -r number language_uri; do
    language_file="data/languages/${language_uri##*/}.xml"
    [[ -s "$language_file" ]] || continue
    language_code=$(sed -nE 's@.*euvoc#ISO_639_1">([^<]+)</skos:notation>@\1@p' "$language_file" | head -n 1 | tr '[:upper:]' '[:lower:]')
    [[ -n "$language_code" ]] && printf '%s\t%s\n' "$number" "$language_code" >> "$language_map"
  done < <(jq -r '
    .data[] | .recorded_in_a_realization_of[]?
    | (.originalLanguage | map(select(. != "http://publications.europa.eu/resource/authority/language/ENG")) | first) as $source_language
    | select(.number and $source_language) | [.number, $source_language] | @tsv
  ' "$directory/speeches.json")

  LC_ALL=C awk -v language_map="$language_map" '
    function trim(value) { sub(/^[ \t\r\n\f]+/, "", value); sub(/[ \t\r\n\f]+$/, "", value); return value }
    function clean(value) { gsub(/[ \t\r\n\f]+/, " ", value); while (match(value, /[ \t\r\n\f]+[,.;:!?]/)) value = substr(value, 1, RSTART - 1) substr(value, RSTART + RLENGTH - 1, 1) substr(value, RSTART + RLENGTH); return trim(value) }
    function json_escape(value) { gsub(/\\/, "\\\\", value); gsub(/"/, "\\\"", value); gsub(/\n/, "\\n", value); gsub(/\r/, "\\r", value); return value }
    function flush_turn(    code) { if (!speaker || !speech_number || !buffer || !(speech_number in languages) || (speech_number in seen)) return; code = languages[speech_number]; printf "{\"speechNumber\":\"%s\",\"sourceLanguage\":\"%s\",\"sourceText\":\"%s\"}\n", json_escape(speech_number), json_escape(code), json_escape(buffer); seen[speech_number] = 1 }
    function process_paragraph(    i,line,text,bookmark,part,without_speaker) {
      text = ""; bookmark = ""
      for (i = 1; i <= paragraph_lines; i++) { line = paragraph[i]; if (line ~ /<w:bookmarkStart/) { bookmark = line; sub(/^.*w:name="/, "", bookmark); sub(/".*$/, "", bookmark) }; if (line ~ /<w:t([[:space:]][^>]*)?>/) { part = line; sub(/^.*<w:t([^>]*)>/, "", part); sub(/<\/w:t>.*$/, "", part); gsub(/&amp;/, "\\&", part); gsub(/&quot;/, "\\\"", part); gsub(/&apos;/, "\047", part); gsub(/&lt;/, "<", part); gsub(/&gt;/, ">", part); text = text part } else if (line ~ /<w:(tab|br|cr)\/>/) text = text " " }
      text = clean(text)
      if (text != "" && bookmark ~ /^_Toc/) { flush_turn(); speaker = ""; speech_number = ""; buffer = "" }
      else if (text ~ /^[0-9]+-[0-9]+-[0-9]+$/ && bookmark != "") { flush_turn(); speaker = bookmark; sub(/^[0-9]+-[0-9]+-[0-9]+[ \t]*/, "", speaker); speech_number = text; buffer = "" }
      else if (speaker != "" && text != "") { if (buffer == "") { without_speaker = text; sub(speaker, "", without_speaker); if (without_speaker != text) sub(/^[^–]*–[ \t]*/, "", without_speaker); text = without_speaker }; if (text != "") buffer = (buffer == "" ? text : buffer "\n\n" text) }
    }
    BEGIN { while ((getline line < language_map) > 0) { split(line, fields, "\t"); languages[fields[1]] = fields[2] }; close(language_map); in_paragraph = 0; paragraph_lines = 0 }
    /^[ \t]*<w:p>$/ { in_paragraph = 1; paragraph_lines = 0 }
    in_paragraph { paragraph[++paragraph_lines] = $0 }
    /^[ \t]*<\/w:p>$/ && in_paragraph { process_paragraph(); delete paragraph; in_paragraph = 0; paragraph_lines = 0 }
    END { flush_turn() }
  ' "$directory/transcript.xml"
  rm -f "$language_map"
}

cache_transcript_translations() {
  local voting_date="$1"
  local directory="$2"
  local translations_file="$directory/translations.json"
  local candidate speech_number source_language source_text translated_text translations_temporary candidates_file
  if [[ ! -s "$translations_file" ]]; then
    translations_temporary=$(make_temporary_file "translations")
    jq -n '{version: 1, translations: {}}' > "$translations_temporary"
    mv "$translations_temporary" "$translations_file"
  fi
  candidates_file=$(mktemp "${TMPDIR:-/tmp}/eu-moles-translation-candidates.XXXXXX")
  generate_translation_candidates "$directory" > "$candidates_file"
  translations_temporary=$(make_temporary_file "translations")
  if ! jq --slurpfile candidates "$candidates_file" '.translations |= with_entries(select(.key as $speech_number | $candidates | any(.speechNumber == $speech_number)))' "$translations_file" > "$translations_temporary"; then
    rm -f "$translations_temporary" "$candidates_file"; return 1
  fi
  mv "$translations_temporary" "$translations_file"
  translation_total=$(jq -s 'length' "$candidates_file")
  translation_current=0
  if (( translation_total == 0 )); then
    progress_note "Translations: all cached contributions are current"
  fi
  while IFS= read -r candidate; do
    translation_current=$((translation_current + 1))
    speech_number=$(jq -r '.speechNumber' <<< "$candidate"); source_language=$(jq -r '.sourceLanguage' <<< "$candidate"); source_text=$(jq -r '.sourceText' <<< "$candidate")
    progress_note "Translations: $translation_current/$translation_total — $speech_number ($source_language)"
    if jq -e --arg speech_number "$speech_number" --arg source_language "$source_language" --arg source_text "$source_text" '.translations[$speech_number] | select(.sourceLanguage == $source_language and .sourceText == $source_text and (.englishText | type) == "string" and (.englishText | length) > 0)' "$translations_file" > /dev/null; then continue; fi
    if translated_text=$(translate_speech_to_english "$source_language" "$source_text"); then
      translations_temporary=$(make_temporary_file "translations")
      jq --arg speech_number "$speech_number" --arg source_language "$source_language" --arg source_text "$source_text" --arg translated_text "$translated_text" '.translations[$speech_number] = {sourceLanguage: $source_language, sourceText: $source_text, englishText: $translated_text}' "$translations_file" > "$translations_temporary"
      mv "$translations_temporary" "$translations_file"
    else echo "Translation failed for $speech_number; it will be retried on the next update." >&2; fi
    sleep 0.5
  done < "$candidates_file"
  rm -f "$candidates_file"
}
