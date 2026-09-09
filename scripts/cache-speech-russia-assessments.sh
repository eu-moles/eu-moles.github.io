#!/usr/bin/env bash
set -euo pipefail

# Screen each available English plenary contribution for an explicitly stated
# position that could benefit Russian strategic interests. The assessment is a
# cache beside the official transcript: raw source data remains untouched.
# Bump prompt_version when screening rules change; harmless transcript-format
# changes must not spend tokens regenerating an already screened contribution.

repository_root=$(cd "$(dirname "$0")/.." && pwd)
source "$repository_root/scripts/lib/data-utils.sh"

if (( $# != 1 )); then
  progress_error "Usage: $0 data/votes/YYYY-MM-DD"
  exit 64
fi

directory=$1
transcript_file="$directory/transcript.xml"
speeches_file="$directory/speeches.json"
translations_file="$directory/translations.json"
output_file="$directory/speech-russia-assessments.json"

[[ -s "$transcript_file" && -s "$speeches_file" ]] || exit 0

temporary_languages=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-languages.XXXXXX")
temporary_mep_ids=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-mep-ids.XXXXXX")
temporary_raw_candidates=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-raw.XXXXXX")
temporary_mapped_candidates=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-mapped.XXXXXX")
temporary_candidates=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-candidates.XXXXXX")
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-output.XXXXXX")
temporary_tgpt_error=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-error.XXXXXX")
trap 'rm -f "$temporary_languages" "$temporary_mep_ids" "$temporary_raw_candidates" "$temporary_mapped_candidates" "$temporary_candidates" "$temporary_output" "$temporary_tgpt_error"' EXIT

# Resolve the transcript's speaker label once, while building the cache. The
# frontend must use Parliament's stable MEP ID rather than trying to match a
# display name (which may use another script or spelling in the CRE record).
xmllint --xpath '/meps/mep' data/meps.xml 2>/dev/null \
  | awk 'BEGIN { RS = "</mep>" } {
      if (match($0, /<fullName>([^<]+)<\/fullName>/, name) && match($0, /<id>([^<]+)<\/id>/, id))
        print name[1] "\t" id[1]
    }' > "$temporary_mep_ids"

# The language authority files are fetched before translations. Include every
# known language; a missing language is treated as English only when no other
# language was recorded for that contribution.
while IFS=$'\t' read -r speech_number language_uri; do
  [[ -n "$speech_number" ]] || continue
  language_file="data/languages/${language_uri##*/}.xml"
  language_code=""
  if [[ -n "$language_uri" && -s "$language_file" ]]; then
    language_code=$(sed -nE 's@.*euvoc#ISO_639_1">([^<]+)</skos:notation>@\1@p' "$language_file" | head -n 1 | tr '[:upper:]' '[:lower:]')
  fi
  printf '%s\t%s\n' "$speech_number" "${language_code:-en}" >> "$temporary_languages"
done < <(jq -r '
  .data[] | .recorded_in_a_realization_of[]?
  | select(.number)
  | [.number, (.originalLanguage // [] | first // "")] | @tsv
' "$speeches_file")

# This mirrors the transcript turn extraction used by translations. The cache
# key is the stable speech number from the Parliament transcript.
LC_ALL=C awk -v language_map="$temporary_languages" '
  function trim(value) { sub(/^[ \t\r\n\f]+/, "", value); sub(/[ \t\r\n\f]+$/, "", value); return value }
  function clean(value) { gsub(/[ \t\r\n\f]+/, " ", value); while (match(value, /[ \t\r\n\f]+[,.;:!?]/)) value = substr(value, 1, RSTART - 1) substr(value, RSTART + RLENGTH - 1, 1) substr(value, RSTART + RLENGTH); return trim(value) }
  function json_escape(value) { gsub(/\\/, "\\\\", value); gsub(/"/, "\\\"", value); gsub(/\n/, "\\n", value); gsub(/\r/, "\\r", value); return value }
  function strip_initial_attribution(value) {
    # CRE paragraphs can begin with editorial speaker/group metadata such as
    # “Name (Group). –”, or “, on behalf of Group. –”, in any language.
    # Those labels are not remarks and must never reach the translation or AI
    # assessment pipeline.
    sub(/^[^(\r\n]*\([^)]*\)\.[[:space:]]*[–—-][[:space:]]*/, "", value)
    sub(/^,[^.\r\n]*\.[[:space:]]*[–—-][[:space:]]*/, "", value)
    return value
  }
  function flush_turn(    code,speaker_label,opening) {
    if (!speaker || !speech_number || !buffer || (speech_number in seen)) return
    code = languages[speech_number]; if (code == "") code = "en"
    speaker_label = speaker
    opening = buffer; sub(/\n\n.*/, "", opening)
    if (opening ~ /[[:space:]]\([^)]*\)\.?[[:space:]]*[–—-]/) {
      sub(/[[:space:]]\([^)]*\)\.?[[:space:]]*[–—-].*$/, "", opening)
      if (opening != "") speaker_label = opening
    }
    # The English MEP directory records this CRE speaker in Latin script. The
    # transcript also puts the group attribution before his actual remarks.
    if (speaker_label == "Петър Волгин") {
      speaker_label = "Petar VOLGIN"
    }
    buffer = strip_initial_attribution(buffer)
    printf "{\"speechNumber\":\"%s\",\"speaker\":\"%s\",\"sourceLanguage\":\"%s\",\"sourceText\":\"%s\"}\n", json_escape(speech_number), json_escape(speaker_label), json_escape(code), json_escape(buffer)
    seen[speech_number] = 1
  }
  function process_paragraph(    i,line,text,bookmark,part,without_speaker) {
    text = ""; bookmark = ""
    for (i = 1; i <= paragraph_lines; i++) {
      line = paragraph[i]
      if (line ~ /<w:bookmarkStart/) { bookmark = line; sub(/^.*w:name="/, "", bookmark); sub(/".*$/, "", bookmark) }
      if (line ~ /<w:t([[:space:]][^>]*)?>/) { part = line; sub(/^.*<w:t([^>]*)>/, "", part); sub(/<\/w:t>.*$/, "", part); gsub(/&amp;/, "\\&", part); gsub(/&quot;/, "\\\"", part); gsub(/&apos;/, "\047", part); gsub(/&lt;/, "<", part); gsub(/&gt;/, ">", part); text = text part }
      else if (line ~ /<w:(tab|br|cr)\/>/) text = text " "
    }
    text = clean(text)
    if (text != "" && bookmark ~ /^_Toc/) { flush_turn(); speaker = ""; speech_number = ""; buffer = "" }
    else if (text ~ /^[0-9]+-[0-9]+-[0-9]+$/ && bookmark != "") { flush_turn(); speaker = bookmark; sub(/^[0-9]+-[0-9]+-[0-9]+[ \t]*/, "", speaker); speech_number = text; buffer = "" }
    else if (speaker != "" && text != "") {
      if (buffer == "") { without_speaker = text; sub(speaker, "", without_speaker); if (without_speaker != text) sub(/^[^–]*–[ \t]*/, "", without_speaker); text = without_speaker }
      if (text != "") buffer = (buffer == "" ? text : buffer "\n\n" text)
    }
  }
  BEGIN { while ((getline line < language_map) > 0) { split(line, fields, "\t"); languages[fields[1]] = fields[2] }; close(language_map); in_paragraph = 0; paragraph_lines = 0 }
  /^[ \t]*<w:p>$/ { in_paragraph = 1; paragraph_lines = 0 }
  in_paragraph { paragraph[++paragraph_lines] = $0 }
  /^[ \t]*<\/w:p>$/ && in_paragraph { process_paragraph(); delete paragraph; in_paragraph = 0; paragraph_lines = 0 }
  END { flush_turn() }
' "$transcript_file" > "$temporary_raw_candidates"

# Unicode case-folding is important here: Parliament's directory capitalises
# surnames, while CRE records usually use title case. Node handles names such
# as ZAJĄCZKOWSKA-HERNIK correctly where jq's ASCII folding cannot.
node -e '
  const fs = require("fs");
  const normalise = (value) => String(value || "").normalize("NFC").toLowerCase();
  const ids = new Map();
  for (const line of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
    const [name, id] = line.split("\t");
    if (name && id) ids.set(normalise(name), id);
  }
  for (const line of fs.readFileSync(0, "utf8").trim().split("\n")) {
    if (!line) continue;
    const candidate = JSON.parse(line);
    const mepID = ids.get(normalise(candidate.speaker));
    if (mepID) process.stdout.write(`${JSON.stringify({...candidate, mepID})}\n`);
  }
' "$temporary_mep_ids" < "$temporary_raw_candidates" > "$temporary_mapped_candidates"

if [[ -s "$translations_file" ]]; then
  jq -n --slurpfile raw "$temporary_mapped_candidates" --slurpfile translations "$translations_file" '
    def strip_initial_attribution:
      sub("^[^\\(\\r\\n]*\\([^\\)\\r\\n]*\\)\\.[[:space:]]*[–—-][[:space:]]*"; "")
      | sub("^,[^\\.\\r\\n]*\\.[[:space:]]*[–—-][[:space:]]*"; "");
    ($translations[0].translations // {}) as $translations
    | [
        $raw[]
        | . as $candidate
        | ($translations[$candidate.speechNumber] // {}) as $translation
        | if $candidate.sourceLanguage == "en" then
            $candidate + {englishText: $candidate.sourceText, textOrigin: "original English"}
          # Transcript cleanup may remove a CRE lead-in (for example, “on
          # behalf of …”), while the translation cache still contains the
          # earlier source string. The official contribution is unchanged, so
          # retain its already-cached translation instead of dropping it.
          elif (($translation.englishText // "") | type == "string" and length > 0) then
            $candidate + {
              englishText: ($translation.englishText | strip_initial_attribution),
              textOrigin: "machine translation"
            }
          else empty end
      ]
  ' > "$temporary_candidates"
else
  jq -n --slurpfile raw "$temporary_mapped_candidates" \
    '[$raw[] | select(.sourceLanguage == "en") | . + {englishText: .sourceText, textOrigin: "original English"}]' > "$temporary_candidates"
fi

if [[ ! -s "$output_file" ]]; then
  printf '{"version":1,"items":{}}\n' > "$output_file"
fi

prompt_version=5
if [[ -s "$output_file" ]]; then
  existing_file="$output_file"
else
  existing_file=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-existing.XXXXXX")
  printf '{"version":1,"items":{}}\n' > "$existing_file"
fi

jq \
  --argjson prompt_version "$prompt_version" \
  --slurpfile candidates "$temporary_candidates" \
  --slurpfile existing "$existing_file" '
  def usable: (.benefitsRussia | type) == "boolean";
  def unavailable: .assessmentStatus == "unavailable";
  reduce $candidates[0][] as $candidate (
    {version: 1, items: {}};
    ($existing[0].items[$candidate.speechNumber] // {}) as $previous
    | ($previous.promptVersion == $prompt_version
      and ($previous | (usable or unavailable))) as $cached
    | .items[$candidate.speechNumber] = {
        sourceLanguage: $candidate.sourceLanguage,
        speaker: $candidate.speaker,
        mepID: $candidate.mepID,
        sourceText: $candidate.sourceText,
        englishText: $candidate.englishText,
        textOrigin: $candidate.textOrigin,
        promptVersion: $prompt_version,
        benefitsRussia: (if $cached then $previous.benefitsRussia else null end),
        assessmentStatus: (if $cached then ($previous.assessmentStatus // (if ($previous | usable) then "complete" else "unavailable" end)) else "pending" end),
        generatedAt: (if $cached then ($previous.generatedAt // null) else null end)
      }
  )
' "$existing_file" > "$temporary_output"
mv -f "$temporary_output" "$output_file"
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-output.XXXXXX")
[[ "$existing_file" == "$output_file" ]] || rm -f "$existing_file"

if [[ ${SPEECH_RUSSIA_SKIP_GENERATION:-false} == true ]]; then
  progress_note "Speech Russia assessments: cache prepared; generation was skipped."
  exit 0
fi

tgpt_bin=tgpt
tgpt_provider=${TGPT_PROVIDER:-}

compact_text() {
  tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

normalise_json_response() {
  # Gemini occasionally wraps an otherwise valid one-line object in a Markdown
  # fence. It carries no useful information for this machine-readable cache.
  compact_text | sed -E 's/^```[[:alnum:]_-]*[[:space:]]*//; s/[[:space:]]*```$//'
}

is_valid_assessment() {
  jq -e 'type == "object" and (keys | sort == ["benefitsRussia"]) and (.benefitsRussia | type == "boolean")' <<< "$1" > /dev/null 2>&1
}

redact_graphic_content_for_assessment() {
  # Provider safety systems can suppress an otherwise ordinary policy-screening
  # request when a speech quotes graphic sexual violence or slurs. Those details
  # are irrelevant to this narrowly scoped Russia-benefit assessment.
  awk 'BEGIN { RS = ""; ORS = "\n\n" }
    {
      normalised = tolower($0)
      if (normalised ~ /(rape|raped|sexual abuse|sexual violence|vagina|anus|abortion|miscarriage|whore|slut|grooming gang)/) {
        print "[Graphic sexual-violence details omitted. Assess only the policy positions in the remaining contribution.]"
      } else {
        print $0
      }
    }'
}

assessment_instructions='Screen this single European Parliament debate contribution for a data flag. Analyse the concrete policy position expressed, not the speaker, party, nationality, tone, factual accuracy or rhetorical hostility. Output only a one-line JSON object with exactly one boolean key: benefitsRussia.

Set benefitsRussia to true only if the contribution advocates, endorses, or clearly argues for a concrete outcome that would reasonably benefit Russian strategic interests by weakening European security or support for Ukraine or Moldova. This includes ending, reducing or obstructing sanctions; military, financial or economic support for Ukraine; EU or NATO defence and security coordination; European defence investment; energy independence; or counter-disinformation.

In the context of Russia’s war against Ukraine, treat calls against weapons deliveries, rearmament, militarisation, NATO security, escalation or a “war against Russia” as true when they present less European military support or deterrence as the preferred outcome, even if framed as peace. Also treat it as true when the speaker explicitly calls to stop or reverse Ukraine or Moldova EU integration while arguing that support must be diverted from it, or that integration itself must be stopped to avoid war, escalation, confrontation with Russia, or NATO-driven conflict.

Always set benefitsRussia to false for an accession objection based on historical memory, wartime atrocities, symbols, national identity, corruption, costs, minority rights, national interest or domestic politics—even when it says Ukraine should never join the EU—unless the contribution independently calls to reduce support or links the requested block to war, escalation, Russia or NATO. Also set it to false for factual reporting; criticism without a requested policy change; peace language that still supports Ukraine’s sovereignty and continuing assistance; and criticism of military spending unrelated to Russia’s war against Ukraine. Do not guess motives.'

assessment_total=$(jq '.items | length' "$output_file")
pending_total=$(jq '[.items[] | select(.assessmentStatus == "pending")] | length' "$output_file")
retry_delay_seconds=${SPEECH_RUSSIA_RETRY_DELAY_SECONDS:-2}
max_empty_response_attempts=3
progress_note "Speech Russia assessments: $pending_total/$assessment_total response(s) need generating"

response_current=0
while IFS= read -r candidate; do
  response_current=$((response_current + 1))
  speech_number=$(jq -r '.key' <<< "$candidate")
  if [[ $(jq -r '.value.assessmentStatus' <<< "$candidate") != "pending" ]]; then
    progress_note "Speech Russia assessments: response $response_current/$assessment_total cached ($speech_number)"
    continue
  fi

  source_language=$(jq -r '.value.sourceLanguage' <<< "$candidate")
  text_origin=$(jq -r '.value.textOrigin' <<< "$candidate")
  english_text=$(jq -r '.value.englishText' <<< "$candidate")
  # Long contributions are rare. Preserve both their opening context and
  # conclusion without turning one screening request into a very large prompt.
  if (( ${#english_text} > 12000 )); then
    english_text="${english_text:0:9000}"$'\n\n[Middle of contribution omitted for length]\n\n'"${english_text: -3000}"
  fi
  assessment_text=$(printf '%s' "$english_text" | redact_graphic_content_for_assessment)
  if [[ "$assessment_text" != "$english_text" ]]; then
    progress_note "Speech Russia assessments: redacted graphic detail for provider safety ($speech_number)"
  fi
  prompt=$(printf '%s\n\nContribution number: %s\nEnglish text source: %s (%s)\n--- contribution ---\n%s\n--- end contribution ---' \
    "$assessment_instructions" "$speech_number" "$text_origin" "$source_language" "$assessment_text")

  progress_note "Speech Russia assessments: response $response_current/$assessment_total generating ($speech_number)"
  attempt=0
  empty_response_attempts=0
  assessment_ready=false
  while :; do
    attempt=$((attempt + 1))
    answer=""
    : > "$temporary_tgpt_error"
    if [[ -n "$tgpt_provider" ]]; then
      answer=$("$tgpt_bin" --provider "$tgpt_provider" -q "$prompt" </dev/null 2>"$temporary_tgpt_error" | normalise_json_response) || answer=""
    else
      answer=$("$tgpt_bin" -q "$prompt" </dev/null 2>"$temporary_tgpt_error" | normalise_json_response) || answer=""
    fi
    if is_valid_assessment "$answer"; then
      assessment_ready=true
      break
    fi

    tgpt_error=$(compact_text < "$temporary_tgpt_error")
    if [[ -n "$tgpt_error" ]]; then
      progress_error "Speech Russia assessments: attempt $attempt for $speech_number error: ${tgpt_error:0:600}"
    elif [[ -n "$answer" ]]; then
      progress_error "Speech Russia assessments: attempt $attempt for $speech_number returned invalid output: ${answer:0:600}"
    else
      empty_response_attempts=$((empty_response_attempts + 1))
      progress_error "Speech Russia assessments: attempt $attempt for $speech_number returned no output"
      if (( empty_response_attempts >= max_empty_response_attempts )); then
        progress_error "Speech Russia assessments: $speech_number returned no output $max_empty_response_attempts times; caching it as unavailable until the screening prompt changes."
        jq \
          --arg speech_number "$speech_number" \
          --arg generated_at "$(date --iso-8601=seconds)" \
          '.items[$speech_number].assessmentStatus = "unavailable" | .items[$speech_number].generatedAt = $generated_at' \
          "$output_file" > "$temporary_output"
        mv -f "$temporary_output" "$output_file"
        temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-output.XXXXXX")
        break
      fi
    fi
    progress_note "Speech Russia assessments: attempt $attempt for $speech_number was unusable; retrying in ${retry_delay_seconds}s"
    sleep "$retry_delay_seconds"
  done

  [[ "$assessment_ready" == true ]] || continue

  jq \
    --arg speech_number "$speech_number" \
    --argjson benefits_russia "$(jq -c '.benefitsRussia' <<< "$answer")" \
    --arg generated_at "$(date --iso-8601=seconds)" \
    '.items[$speech_number].benefitsRussia = $benefits_russia | .items[$speech_number].assessmentStatus = "complete" | .items[$speech_number].generatedAt = $generated_at' \
    "$output_file" > "$temporary_output"
  mv -f "$temporary_output" "$output_file"
  temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-output.XXXXXX")
  progress_note "Speech Russia assessments: generated $speech_number"
done < <(jq -c '.items | to_entries[]' "$output_file")
