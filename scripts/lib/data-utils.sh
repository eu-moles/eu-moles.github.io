#!/usr/bin/env bash

# Shared download, validation, and formatting helpers. This file is sourced by
# the update entry points after they switch to the repository's src directory.

progress() {
  local current="$1"
  local total="$2"
  local message="$3"
  local percent=0

  if (( total > 0 )); then
    percent=$((current * 100 / total))
  fi
  printf '[%s] %3d%% (%d/%d) %s\n' "$(date +%H:%M:%S)" "$percent" "$current" "$total" "$message"
}

progress_note() {
  printf '[%s]       %s\n' "$(date +%H:%M:%S)" "$1"
}

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

fetch_json() {
  local url="$1"
  local destination="$2"
  local temporary
  local formatted

  temporary=$(make_temporary_file "fetch-json")
  formatted=$(make_temporary_file "format-json")
  progress_note "Downloading JSON: $destination"
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
  progress_note "Downloading XML: $destination"
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
  progress_note "Downloading language authority: $destination"
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
  progress_note "Downloading transcript document: $destination"
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
