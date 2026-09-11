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

progress_error() {
  printf '[%s]       %s\n' "$(date +%H:%M:%S)" "$1" >&2
}

load_gemini_environment() {
  local environment_file="$1"

  if [[ ! -r "$environment_file" ]]; then
    progress_error "Gemini configuration is missing: expected $environment_file"
    return 1
  fi

  # The project .env is user-owned and Git-ignored. Export its assignments so
  # the background workers used by the caches inherit the same configuration.
  set -a
  # shellcheck disable=SC1090
  source "$environment_file"
  set +a

  if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    progress_error "Gemini configuration is missing GEMINI_API_KEY in $environment_file"
    return 1
  fi
  if [[ -z "${GEMINI_MODEL:-}" ]]; then
    progress_error "Gemini configuration is missing GEMINI_MODEL in $environment_file"
    return 1
  fi
}

gemini_generate_json() {
  local prompt="$1"
  local max_output_tokens="$2"
  local model payload response text error_message

  if [[ -z "${GEMINI_API_KEY:-}" || -z "${GEMINI_MODEL:-}" ]]; then
    progress_error "Gemini is not configured. Run the updater through ./update_data.sh so it loads .env."
    return 64
  fi
  if ! [[ "$max_output_tokens" =~ ^[1-9][0-9]*$ ]]; then
    progress_error "Gemini max output tokens must be a positive integer (received $max_output_tokens)."
    return 64
  fi

  model=${GEMINI_MODEL#models/}
  if ! [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
    progress_error "Gemini model name contains unsupported characters."
    return 64
  fi

  payload=$(jq -cn \
    --arg prompt "$prompt" \
    --argjson max_output_tokens "$max_output_tokens" \
    '{
      contents: [{role: "user", parts: [{text: $prompt}]}],
      generationConfig: {
        temperature: 0,
        responseMimeType: "application/json",
        maxOutputTokens: $max_output_tokens
      }
    }')

  if ! response=$(curl_with_error_url \
    -fsSL \
    --connect-timeout 15 \
    --max-time 180 \
    --retry 0 \
    -H 'Content-Type: application/json' \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    --data-binary "$payload" \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent"); then
    return 1
  fi

  if text=$(jq -er '[.candidates[0].content.parts[]?.text // empty] | join("") | select(length > 0)' <<< "$response" 2>/dev/null); then
    printf '%s' "$text"
    return 0
  fi

  error_message=$(jq -r '.error.message // .promptFeedback.blockReason // .candidates[0].finishReason // "Gemini returned no candidate text"' <<< "$response" 2>/dev/null || true)
  progress_error "Gemini response error: $error_message"
  return 1
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
  local rate_limit_attempt=0
  local max_rate_limit_retries=5
  local rate_limit_delay_seconds=15

  error_log=$(make_temporary_file "curl-error")
  while :; do
    : > "$error_log"
    if curl --stderr "$error_log" "$@"; then
      status=0
    else
      status=$?
    fi

    if (( status != 0 )) && grep -Eq '(^|[^0-9])429([^0-9]|$)' "$error_log" && (( rate_limit_attempt < max_rate_limit_retries )); then
      rate_limit_attempt=$((rate_limit_attempt + 1))
      progress_error "curl request was rate-limited (HTTP 429); retry $rate_limit_attempt/$max_rate_limit_retries in ${rate_limit_delay_seconds}s: $url"
      sleep "$rate_limit_delay_seconds"
      continue
    fi
    break
  done

  while IFS= read -r error_line || [[ -n "$error_line" ]]; do
    progress_error "$error_line"
  done < "$error_log"
  if grep -q '^curl: (' "$error_log"; then
    progress_error "curl request URL: $url"
  fi
  rm -f "$error_log"
  return "$status"
}

fetch_json() {
  local url="$1"
  local destination="$2"
  local max_time="${3:-45}"
  local retry_count="${4:-2}"
  local temporary
  local formatted

  temporary=$(make_temporary_file "fetch-json")
  formatted=$(make_temporary_file "format-json")
  progress_note "Downloading JSON: $destination"
  if curl_with_error_url -fsSL --connect-timeout 10 --max-time "$max_time" --retry "$retry_count" --retry-delay 1 \
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
