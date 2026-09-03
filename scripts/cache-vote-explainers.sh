#!/usr/bin/env bash
set -euo pipefail

# Build a small, reviewable AI context bundle for every child roll-call vote in
# a sitting. The bundle is kept even if tgpt is unavailable, so the official
# source links are always available to the site and generation can resume on a
# later update without rebuilding the source catalogue.

if (( $# != 1 )); then
  echo "Usage: $0 data/votes/YYYY-MM-DD" >&2
  exit 64
fi

directory=$1
votes_file="$directory/vote-results.json"
decisions_file="$directory/decisions.json"
procedures_directory="$directory/procedures"
output_file="$directory/vote-explainers.json"
amendment_texts_file="$directory/amendment-texts.json"

[[ -s "$votes_file" && -s "$decisions_file" ]] || exit 0

temporary_candidates=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-candidates.XXXXXX")
temporary_procedures=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-procedures.XXXXXX")
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainers.XXXXXX")
temporary_amendment_texts=$(mktemp "${TMPDIR:-/tmp}/eu-moles-amendment-texts.XXXXXX")
trap 'rm -f "$temporary_candidates" "$temporary_procedures" "$temporary_output" "$temporary_amendment_texts"' EXIT

procedure_files=()
if [[ -d "$procedures_directory" ]]; then
  while IFS= read -r -d '' procedure_file; do
    procedure_files+=("$procedure_file")
  done < <(find "$procedures_directory" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
fi

if ((${#procedure_files[@]})); then
  jq -s '[.[].data[]?]' "${procedure_files[@]}" > "$temporary_procedures"
else
  printf '[]\n' > "$temporary_procedures"
fi

# Each candidate names the exact vote and supplies only official Parliament
# sources. Amendment tables are selected by their published amendment range.
jq -n \
  --slurpfile votes "$votes_file" \
  --slurpfile decisions "$decisions_file" \
  --slurpfile procedures "$temporary_procedures" '
  def array: if type == "array" then . elif . == null then [] else [.] end;
  def document_id:
    if type == "object" then (.id // "") else . end
    | split("/") | last;
  def document_url($document):
    "https://www.europarl.europa.eu/doceo/document/\($document)_EN.html";
  def activity_documents:
    (.based_on_a_realization_of // .decided_on_a_realization_of // [] | array[] | document_id);
  def amendment_source($reference; $label; $procedures):
    ($label | try capture("(?i)\\bAm\\s+(?<number>[0-9]+)") catch {}) as $amendment
    | ($reference | try capture("^(?<family>[A-Z]+)(?<term>[0-9]+)-(?<number>[0-9]+)/(?<year>[0-9]{4})$") catch {}) as $reference_parts
    | if ($amendment.number? and $reference_parts.family?) then
        "\($reference_parts.family)-\($reference_parts.term)-\($reference_parts.year)-\($reference_parts.number)" as $base
        | ([
            $procedures[]?
            | .consists_of[]?
            | activity_documents
            | select(startswith($base + "-AM-"))
            | . as $document
            | (try ($document | capture("-AM-(?<first>[0-9]+)-(?<last>[0-9]+)$")) catch null) as $range
            | select($range != null and ($amendment.number | tonumber) >= ($range.first | tonumber) and ($amendment.number | tonumber) <= ($range.last | tonumber))
            | {
                id: $document,
                distribution: (
                  if $reference_parts.family == "A" then "reds_iPlRp_Amd"
                  elif $reference_parts.family == "B" then "reds_iPlRe_Amd"
                  elif $reference_parts.family == "RC" then "reds_iPlRc_Amd"
                  else ""
                  end
                )
              }
          ] | sort_by(.id) | .[0]) as $document
        | if ($document.distribution? // "") != "" then
            {
              label: "Amendment text",
              url: "https://data.europarl.europa.eu/distribution/\($document.distribution)/\($document.id)/\($document.id)_en.pdf"
            }
          else empty end
      else empty end;
  def procedure_sources($vote; $procedures):
    [
      ($vote.inverse_consists_of // [] | array[] | if type == "object" then (.id // "") else . end)
      | capture("/proc/(?<id>[0-9]{4}-[0-9]{4})$")?.id
    ]
    | unique[] as $procedure_id
    | ($procedures[]? | select((.id // "") | endswith("/proc/" + $procedure_id)) | .label // empty)
    | select(test("^[0-9]{4}/[0-9]{4}\\([A-Z]+\\)$"))
    | {
        label: "Procedure overview (OEIL)",
        url: "https://oeil.europarl.europa.eu/oeil/en/procedure-file?reference=\(. | @uri)"
      };
  ($votes[0].data // []) as $votes_data
  | ($decisions[0].data // []) as $decisions_data
  | ($procedures[0] // []) as $procedure_data
  | [
      $votes_data[] as $vote
      | ($vote.consists_of // [] | array[] | document_id) as $decision_id
      | ($decisions_data[] | select(.activity_id == $decision_id)) as $decision
      | ($decision.activity_label.en // "") as $label
      | select($label != "")
      | ($label | try capture("(?<reference>[A-Z]+[0-9]+-[0-9]+/[0-9]{4})") catch {}) as $reference_match
      | ($reference_match.reference // "") as $reference
      | ([($decision.recorded_in_a_realization_of // [] | array[] | document_id) | select(test("-RCV-ITM-[0-9]+$"))][0] // "") as $individual_record
      | ([($vote.recorded_in_a_realization_of // [] | array[] | document_id) | select(test("-VOT-ITM-[0-9]+$"))][0] // "") as $parent_record
      | ([
          if $individual_record != "" then {label: "Individual roll-call result", url: document_url($individual_record)} else empty end,
          if $parent_record != "" then {label: "Official vote item", url: document_url($parent_record)} else empty end,
          amendment_source($reference; $label; $procedure_data),
          procedure_sources($vote; $procedure_data)
        ] | unique_by(.url)) as $sources
      | {
          id: $decision.activity_id,
          prompt: (
            "Write a politically neutral plain-English guide for a person unfamiliar with the European Parliament. Output only a valid one-line JSON object with exactly these string keys: description, yesVote, russia. No Markdown, code fence, citations, preface or extra keys. The combined text must be at most 500 Unicode characters including spaces. description (max 220 characters): state the specific real-world policy change, naming the people, institution, money, rule, right, obligation or objective affected. yesVote (max 180 characters): explicitly state what a Yes vote would do or approve. russia (max 100 characters): assess only whether the proposal has a direct or reasonably supported indirect benefit for Russia. If the official text gives no basis for such a link, use this exact text: No direct Russia-related effect is stated. Do not speculate. Never state or imply the outcome: do not say whether it passed, failed, was adopted, rejected, or how anyone voted. Use only the official sources and quoted amendment text below; detailed amendment wording is authoritative.\n\n"
            + "Parent item: \($vote.activity_label.en // "")\n"
            + "Vote detail: \($label)\n"
            + "Official sources:\n"
            + ($sources | map("- \(.label): \(.url)") | join("\n"))
          ),
          sources: $sources
        }
    ]
' > "$temporary_candidates"

# Amendment tables often contain the only precise before/after wording. Cache
# their extracted text once, then supply it directly to tgpt instead of hoping
# that a web chat follows a PDF link.
if [[ ! -s "$amendment_texts_file" ]]; then
  printf '{"version":1,"documents":{}}\n' > "$amendment_texts_file"
fi

amendment_total=$(jq '[.[] | .sources[]? | select(.label == "Amendment text") | .url] | unique | length' "$temporary_candidates")
amendment_current=0
while IFS= read -r amendment_url; do
  amendment_current=$((amendment_current + 1))
  amendment_document=${amendment_url##*/}
  amendment_document=${amendment_document%_en.pdf}
  [[ -n "$amendment_document" ]] || continue

  if jq -e --arg document "$amendment_document" '.documents[$document].text | strings | length > 0' "$amendment_texts_file" > /dev/null; then
    printf 'Vote explainers: amendment text %d/%d cached (%s)\n' "$amendment_current" "$amendment_total" "$amendment_document" >&2
    continue
  fi

  printf 'Vote explainers: amendment text %d/%d downloading (%s)\n' "$amendment_current" "$amendment_total" "$amendment_document" >&2

  amendment_pdf=$(mktemp "${TMPDIR:-/tmp}/eu-moles-amendment-pdf.XXXXXX")
  amendment_text=$(mktemp "${TMPDIR:-/tmp}/eu-moles-amendment-text.XXXXXX")
  if curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 --output "$amendment_pdf" "$amendment_url" &&
    pdftotext -layout "$amendment_pdf" "$amendment_text" &&
    [[ -s "$amendment_text" ]]; then
    jq \
      --arg document "$amendment_document" \
      --arg url "$amendment_url" \
      --rawfile text "$amendment_text" \
      '.documents[$document] = {url: $url, text: $text}' \
      "$amendment_texts_file" > "$temporary_amendment_texts"
    mv -f "$temporary_amendment_texts" "$amendment_texts_file"
    temporary_amendment_texts=$(mktemp "${TMPDIR:-/tmp}/eu-moles-amendment-texts.XXXXXX")
  else
    echo "Vote explainers: could not extract $amendment_url; the linked source will be retried next update." >&2
  fi
  rm -f "$amendment_pdf" "$amendment_text"
done < <(jq -r '[.[] | .sources[]? | select(.label == "Amendment text") | .url] | unique[]' "$temporary_candidates")

printf 'Vote explainers: source text cached; preparing %s response record(s)\n' "$(jq 'length' "$temporary_candidates")" >&2
if [[ -s "$output_file" ]]; then
  existing_file="$output_file"
else
  existing_file=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainers-existing.XXXXXX")
  printf '{"version":1,"items":{}}\n' > "$existing_file"
fi

jq \
  --slurpfile candidates "$temporary_candidates" \
  --slurpfile existing "$existing_file" '
  def usable_sections:
    type == "object"
    and ((.description // "") | type == "string" and length > 0 and length <= 220)
    and ((.yesVote // "") | type == "string" and length > 0 and length <= 180)
    and ((.russia // "") | type == "string" and length > 0 and length <= 100)
    and ([.description, .yesVote, .russia] | join(" ") | length <= 500)
    and ([.description, .yesVote, .russia] | join(" ") | test("DeepSeek Web Error|MISSING_HEADER|Some error has occurred|failed to create chat session|^Error:|^Warning:"; "i") | not);
  reduce $candidates[0][] as $candidate (
    {version: 1, items: {}};
    (($existing[0].items[$candidate.id] // {})) as $previous
    | .items[$candidate.id] = {
        prompt: $candidate.prompt,
        sources: $candidate.sources,
        description: (if $previous.prompt == $candidate.prompt and ($previous | usable_sections) then $previous.description else "" end),
        yesVote: (if $previous.prompt == $candidate.prompt and ($previous | usable_sections) then $previous.yesVote else "" end),
        russia: (if $previous.prompt == $candidate.prompt and ($previous | usable_sections) then $previous.russia else "" end),
        generatedAt: ($previous.generatedAt // null)
      }
  )
' "$existing_file" > "$temporary_output"
mv -f "$temporary_output" "$output_file"
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainers.XXXXXX")
[[ "$existing_file" == "$output_file" ]] || rm -f "$existing_file"

tgpt_bin=${TGPT_BIN:-tgpt}
if ! command -v "$tgpt_bin" > /dev/null 2>&1; then
  for candidate in /home/linuxbrew/.linuxbrew/opt/tgpt/bin/tgpt /opt/homebrew/opt/tgpt/bin/tgpt; do
    if [[ -x "$candidate" ]]; then
      tgpt_bin=$candidate
      break
    fi
  done
fi
if ! command -v "$tgpt_bin" > /dev/null 2>&1; then
  echo "Vote explainers: source bundle saved to $output_file; tgpt was not found, so no new explanations were generated." >&2
  exit 0
fi

# update_data.sh runs non-interactively, so .bashrc's Homebrew shellenv is not
# loaded. DeepSeek Web needs a JS runtime for its proof-of-work challenge.
if [[ -z "${DEEPSEEK_WEB_RUNTIME:-}" ]] && ! command -v node > /dev/null 2>&1 && ! command -v bun > /dev/null 2>&1 && ! command -v deno > /dev/null 2>&1; then
  for runtime in /home/linuxbrew/.linuxbrew/opt/node/bin/node /opt/homebrew/opt/node/bin/node; do
    if [[ -x "$runtime" ]]; then
      export DEEPSEEK_WEB_RUNTIME="$runtime"
      break
    fi
  done
fi

compact_text() {
  tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

is_valid_explainer_sections() {
  local value=$1 text

  jq -e '
    type == "object"
    and ((.description // "") | type == "string" and length > 0 and length <= 220)
    and ((.yesVote // "") | type == "string" and length > 0 and length <= 180)
    and ((.russia // "") | type == "string" and length > 0 and length <= 100)
    and ([.description, .yesVote, .russia] | join(" ") | length <= 500)
  ' <<< "$value" > /dev/null 2>&1 || return 1

  text=$(jq -r '[.description, .yesVote, .russia] | join(" ")' <<< "$value")
  ! grep -Eiq 'DeepSeek Web Error|MISSING_HEADER|Some error has occurred|failed to create chat session|^Error:|^Warning:|\b(passed|failed|adopted|rejected|defeated|voted down|outcome|result|vote tally)\b|did not pass|was not approved' <<< "$text"
}

add_amendment_context() {
  local candidate_value=$1
  local base_prompt=$2
  local amendment_url amendment_document amendment_text

  amendment_url=$(jq -r '[.value.sources[]? | select(.label == "Amendment text") | .url][0] // empty' <<< "$candidate_value")
  [[ -n "$amendment_url" ]] || {
    printf '%s' "$base_prompt"
    return
  }

  amendment_document=${amendment_url##*/}
  amendment_document=${amendment_document%_en.pdf}
  amendment_text=$(jq -r --arg document "$amendment_document" '.documents[$document].text // empty' "$amendment_texts_file")
  [[ -n "$amendment_text" ]] || {
    printf '%s' "$base_prompt"
    return
  }

  printf '%s\n\nThe official amendment table is quoted below. It may contain several amendments: use only the amendment number in Vote detail, explain its actual wording in plain English, and ignore all other rows.\n--- amendment table ---\n%s\n--- end amendment table ---' \
    "$base_prompt" "${amendment_text:0:12000}"
}

pending_total=$(jq '[.items[] | select((.description // "") == "" or (.yesVote // "") == "" or (.russia // "") == "")] | length' "$output_file")
explainer_total=$(jq '.items | length' "$output_file")
retry_delay_seconds=${EXPLAINER_RETRY_DELAY_SECONDS:-15}
printf 'Vote explainers: %d/%d response(s) need generating\n' "$pending_total" "$explainer_total" >&2
if (( pending_total == 0 )); then
  echo "Vote explainers: all $explainer_total cached explanations are current." >&2
fi

response_current=0
while IFS= read -r candidate; do
  response_current=$((response_current + 1))
  id=$(jq -r '.key' <<< "$candidate")
  if [[ $(jq -r '.value.description // empty' <<< "$candidate") != "" && $(jq -r '.value.yesVote // empty' <<< "$candidate") != "" && $(jq -r '.value.russia // empty' <<< "$candidate") != "" ]]; then
    printf 'Vote explainers: response %d/%d cached (%s)\n' "$response_current" "$explainer_total" "$id" >&2
    continue
  fi

  prompt=$(jq -r '.value.prompt' <<< "$candidate")
  answer=""
  printf 'Vote explainers: response %d/%d generating (%s)\n' "$response_current" "$explainer_total" "$id" >&2
  prompt=$(add_amendment_context "$candidate" "$prompt")

  attempt=0
  while :; do
    attempt=$((attempt + 1))
    answer=""
    answer=$("$tgpt_bin" -q "$prompt" </dev/null 2>/dev/null | compact_text) || answer=""

    if is_valid_explainer_sections "$answer"; then
      break
    fi

    printf 'Vote explainers: attempt %d for %s was unusable; retrying in %ss\n' "$attempt" "$id" "$retry_delay_seconds" >&2
    sleep "$retry_delay_seconds"
  done

  jq \
    --arg id "$id" \
    --argjson sections "$answer" \
    --arg generated_at "$(date --iso-8601=seconds)" \
    '.items[$id].description = $sections.description | .items[$id].yesVote = $sections.yesVote | .items[$id].russia = $sections.russia | .items[$id].generatedAt = $generated_at' \
    "$output_file" > "$temporary_output"
  mv -f "$temporary_output" "$output_file"
  temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainers.XXXXXX")
  echo "Vote explainers: generated $id" >&2
done < <(jq -c '.items | to_entries[]' "$output_file")
