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
oeil_document_summaries_file="$directory/oeil-document-summaries.json"
output_file="$directory/vote-explainers.json"

[[ -s "$votes_file" && -s "$decisions_file" ]] || exit 0

temporary_candidates=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-candidates.XXXXXX")
temporary_procedures=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-procedures.XXXXXX")
temporary_oeil_summaries=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-oeil-summaries.XXXXXX")
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainers.XXXXXX")
trap 'rm -f "$temporary_candidates" "$temporary_procedures" "$temporary_oeil_summaries" "$temporary_output"' EXIT

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

if [[ -s "$oeil_document_summaries_file" ]]; then
  jq '.procedures // {}' "$oeil_document_summaries_file" > "$temporary_oeil_summaries"
else
  printf '{}\n' > "$temporary_oeil_summaries"
fi

# Each candidate names the exact vote and supplies only official Parliament
# sources. Amendment tables are selected by their published amendment range.
jq -n \
  --slurpfile votes "$votes_file" \
  --slurpfile decisions "$decisions_file" \
  --slurpfile procedures "$temporary_procedures" \
  --slurpfile summaries "$temporary_oeil_summaries" '
  def array: if type == "array" then . elif . == null then [] else [.] end;
  def document_id:
    if type == "object" then (.id // "") else . end
    | split("/") | last;
  def document_url($document):
    "https://www.europarl.europa.eu/doceo/document/\($document)_EN.html";
  def report_source($reference):
    ($reference | try capture("^(?<family>[A-Z]+)(?<term>[0-9]+)-(?<number>[0-9]+)/(?<year>[0-9]{4})$") catch {}) as $parts
    | if ($parts.family? // "") != "" then
        {
          label: "Parliamentary report",
          url: document_url("\($parts.family)-\($parts.term)-\($parts.year)-\($parts.number)")
        }
      else empty end;
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
  def procedure_summary_sources($vote; $summaries):
    [
      ($vote.inverse_consists_of // [] | array[] | if type == "object" then (.id // "") else . end)
      | capture("/proc/(?<id>[0-9]{4}-[0-9]{4})$")?.id
    ]
    | unique[] as $procedure_id
    | ($summaries[$procedure_id] // {}) as $documents
    | ([
        $documents
        | to_entries[]?
        | select(.key | test("^TA-"))
        | .value
      ] | .[-1]) as $summary
    | select(($summary.url // "") != "")
    | {label: "Procedure summary (OEIL)", url: $summary.url};
  ($votes[0].data // []) as $votes_data
  | ($decisions[0].data // []) as $decisions_data
  | ($procedures[0] // []) as $procedure_data
  | ($summaries[0] // {}) as $summary_data
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
          report_source($reference),
          amendment_source($reference; $label; $procedure_data),
          procedure_summary_sources($vote; $summary_data),
          procedure_sources($vote; $procedure_data)
        ] | unique_by(.url)) as $sources
      | {
          id: $decision.activity_id,
          prompt: (
            "Write a politically neutral plain-English guide for a person unfamiliar with the European Parliament. Output only a valid one-line JSON object with exactly these string keys: description, yesVote, russia. No Markdown, code fence, citations, preface or extra keys. All values together must be at most 500 Unicode characters including spaces. Before responding, silently count the characters in every value. A response exceeding any limit is invalid: shorten it and count again. Prefer short everyday words. Avoid parenthetical text, lists and repetition between fields. description (maximum 150 characters, exactly one sentence; target 110): explain only the central concrete policy change, using at most two representative examples. State that it is a proposal when appropriate; do not present a political group claim as an established fact. yesVote (maximum 130 characters, exactly one sentence; target 90): explicitly say the precise text or policy priority a Yes vote would add, remove, replace or approve; do not merely say it approves an amendment or repeat the description. russia (maximum 150 characters, exactly one sentence; target 120): make an EU-security assessment, not merely a keyword search. A proposal can indirectly benefit Russian state interests even if Russia is never named. Assess whether it could plausibly reduce EU defence investment, military readiness, security cooperation, sanctions enforcement, support for Ukraine, energy independence, economic resilience or EU collective capacity. Do not infer a Russia benefit from a political label alone; state it only when the amendment supports a concrete causal mechanism. If the proposal could credibly constrain one of those EU capabilities, begin with Potentially: and name both the reduced EU capability and the resulting benefit to Russian interests. Do not use vague phrases such as support capacity. Otherwise use this exact text: No supported Russia-related effect is stated. A split-vote label such as Am 3/1 is not evidence of a different amendment: use the linked official amendment document for its wording. Never state or imply the outcome: do not say whether it passed, failed, was adopted, rejected, or how anyone voted. Use only the official source URLs below.\n\n"
            + "Parent item: \($vote.activity_label.en // "")\n"
            + "Vote detail: \($label)\n"
            + "Official sources:\n"
            + ($sources | map("- \(.label): \(.url)") | join("\n"))
          ),
          sources: $sources
        }
    ]
' > "$temporary_candidates"

printf 'Vote explainers: preparing %s response record(s) with official source URLs\n' "$(jq 'length' "$temporary_candidates")" >&2
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
    and ((.description // "") | type == "string" and length > 0 and length <= 150)
    and ((.yesVote // "") | type == "string" and length > 0 and length <= 130)
    and ((.russia // "") | type == "string" and length > 0 and length <= 150)
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
    and ((.description // "") | type == "string" and length > 0 and length <= 150)
    and ((.yesVote // "") | type == "string" and length > 0 and length <= 130)
    and ((.russia // "") | type == "string" and length > 0 and length <= 150)
    and ([.description, .yesVote, .russia] | join(" ") | length <= 500)
  ' <<< "$value" > /dev/null 2>&1 || return 1

  text=$(jq -r '[.description, .yesVote, .russia] | join(" ")' <<< "$value")
  ! grep -Eiq 'DeepSeek Web Error|MISSING_HEADER|Some error has occurred|failed to create chat session|^Error:|^Warning:|\b(passed|failed|adopted|rejected|defeated|voted down|outcome|result|vote tally)\b|did not pass|was not approved' <<< "$text"
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
