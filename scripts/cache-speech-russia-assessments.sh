#!/usr/bin/env bash
set -euo pipefail

# Format the Gemini Russia-benefit and fact-check results for plenary
# contributions. The unified Gemini request already translates non-English
# speeches, screens the text, and performs any necessary web-grounded check.
# Bump prompt_version when screening rules change; harmless transcript-format
# changes must not spend tokens regenerating an already screened contribution.

repository_root=$(cd "$(dirname "$0")/.." && pwd)
source "$repository_root/scripts/lib/data-utils.sh"
source "$repository_root/scripts/lib/translations.sh"

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
trap 'rm -f "$temporary_languages" "$temporary_mep_ids" "$temporary_raw_candidates" "$temporary_mapped_candidates" "$temporary_candidates" "$temporary_output"' EXIT

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
    # Limit removal to known political-group labels so a report title or an
    # ordinary parenthetical phrase can never be mistaken for a lead-in.
    if (match(value, /\(/) && RSTART <= 49 && value ~ /^[^(\r\n]*\((PPE|EPP|S&D|Renew|ECR|PfE|ESN|Verts\/ALE|Greens\/EFA|The Left|GUE\/NGL|NI)[^)]*\)/) sub(/^[^(\r\n]*\([^)]*\)[,.;:]?[^–—\r\n]*[–—-][[:space:]]*/, "", value)
    sub(/^,[^.\r\n]*\.[[:space:]]*[–—-][[:space:]]*/, "", value)
    return value
  }
  function is_procedural_label(value, lower) {
    # These CRE bookmark entries are chair labels, not interventions.
    lower = tolower(value)
    return length(value) <= 120 \
      && lower ~ /^(presid|vorsitz|puhemies|voorzitter|przewodnicz|predsed|talman)/ \
      && lower !~ /[.!?]/
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
    if (is_procedural_label(buffer)) return
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
  jq -n --argjson assessment_prompt_version "$speech_assessment_prompt_version" --slurpfile raw "$temporary_mapped_candidates" --slurpfile translations "$translations_file" '
    def strip_initial_attribution:
      sub("(?i)^[^\\(\\r\\n]{0,48}\\((PPE|EPP|S&D|Renew|ECR|PfE|ESN|Verts/ALE|Greens/EFA|The Left|GUE/NGL|NI)[^\\)\\r\\n]*\\)[,.;:]?[[:space:]]*[^–—\\r\\n]{0,140}[–—-][[:space:]]*"; "")
      | sub("^,[^\\.\\r\\n]*\\.[[:space:]]*[–—-][[:space:]]*"; "");
    ($translations[0].translations // {}) as $translations
    | [
        $raw[]
        | . as $candidate
        | ($translations[$candidate.speechNumber] // {}) as $translation
        | (
            $translation.assessmentPromptVersion == $assessment_prompt_version
            and ($translation.benefitsRussia | type) == "boolean"
            and ($translation.factCheck == null or ($translation.factCheck | type) == "string")
          ) as $has_analysis
        | if $translation.detectedLanguage == "en" then
            $candidate + {
              englishText: $candidate.sourceText,
              textOrigin: "original English",
              combinedBenefitsRussia: (if $has_analysis then $translation.benefitsRussia else null end),
              combinedFactCheck: (if $has_analysis then $translation.factCheck else null end)
            }
          # Transcript cleanup may remove a CRE lead-in (for example, “on
          # behalf of …”), while the translation cache still contains the
          # earlier source string. The official contribution is unchanged, so
          # retain its already-cached translation instead of dropping it.
          elif (($translation.englishText // "") | type == "string" and length > 0) then
            $candidate + {
              englishText: ($translation.englishText | strip_initial_attribution),
              textOrigin: "AI translation",
              combinedBenefitsRussia: (
                if $has_analysis then $translation.benefitsRussia else null end
              ),
              combinedFactCheck: (if $has_analysis then $translation.factCheck else null end)
            }
          elif $candidate.sourceLanguage == "en" then
            $candidate + {
              englishText: $candidate.sourceText,
              textOrigin: "original text; Gemini analysis unavailable",
              combinedBenefitsRussia: null,
              combinedFactCheck: null
            }
          else empty end
      ]
  ' > "$temporary_candidates"
else
  jq -n --slurpfile raw "$temporary_mapped_candidates" \
    '[$raw[] | select(.sourceLanguage == "en") | . + {englishText: .sourceText, textOrigin: "original English", combinedBenefitsRussia: null, combinedFactCheck: null}]' > "$temporary_candidates"
fi

if [[ ! -s "$output_file" ]]; then
  printf '{"version":1,"items":{}}\n' > "$output_file"
fi

prompt_version=$speech_assessment_prompt_version
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
  def usable: (.benefitsRussia | type) == "boolean" and (.factCheck == null or (.factCheck | type) == "string");
  def unavailable: .assessmentStatus == "unavailable";
  reduce $candidates[0][] as $candidate (
    {version: 1, items: {}};
    ($existing[0].items[$candidate.speechNumber] // {}) as $previous
    | (($candidate.combinedBenefitsRussia | type) == "boolean") as $combined
    # A current translation/analysis result must replace an older unavailable
    # placeholder. Only retain a previous fully usable result as the cache.
    | ($previous.promptVersion == $prompt_version
      and ($previous | usable)) as $cached
    | .items[$candidate.speechNumber] = {
        sourceLanguage: $candidate.sourceLanguage,
        speaker: $candidate.speaker,
        mepID: $candidate.mepID,
        sourceText: $candidate.sourceText,
        englishText: $candidate.englishText,
        textOrigin: $candidate.textOrigin,
        promptVersion: $prompt_version,
        benefitsRussia: (if $cached then $previous.benefitsRussia elif $combined then $candidate.combinedBenefitsRussia else null end),
        factCheck: (if $cached then ($previous.factCheck // null) elif $combined then ($candidate.combinedFactCheck // null) else null end),
        assessmentStatus: (if $cached then ($previous.assessmentStatus // (if ($previous | usable) then "complete" else "unavailable" end)) elif $combined then "complete" else "unavailable" end),
        generatedAt: (if $cached then ($previous.generatedAt // null) else null end)
      }
  )
' "$existing_file" > "$temporary_output"
mv -f "$temporary_output" "$output_file"
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-speech-russia-output.XXXXXX")
[[ "$existing_file" == "$output_file" ]] || rm -f "$existing_file"

assessment_total=$(jq '.items | length' "$output_file")
complete_total=$(jq '[.items[] | select(.assessmentStatus == "complete")] | length' "$output_file")
unavailable_total=$(jq '[.items[] | select(.assessmentStatus == "unavailable")] | length' "$output_file")
progress_note "Speech Russia assessments: reused $complete_total Gemini analysis result(s); $unavailable_total unavailable (out of $assessment_total)."
