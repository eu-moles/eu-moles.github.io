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
amendment_texts_file="$directory/amendment-texts.json"
report_texts_file="$directory/report-texts.json"

[[ -s "$votes_file" && -s "$decisions_file" ]] || exit 0

temporary_candidates=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-candidates.XXXXXX")
temporary_procedures=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-procedures.XXXXXX")
temporary_oeil_summaries=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-oeil-summaries.XXXXXX")
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainers.XXXXXX")
temporary_amendment_texts=$(mktemp "${TMPDIR:-/tmp}/eu-moles-amendment-texts.XXXXXX")
temporary_report_texts=$(mktemp "${TMPDIR:-/tmp}/eu-moles-report-texts.XXXXXX")
temporary_tgpt_error=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainer-error.XXXXXX")
trap 'rm -f "$temporary_candidates" "$temporary_procedures" "$temporary_oeil_summaries" "$temporary_output" "$temporary_amendment_texts" "$temporary_report_texts" "$temporary_tgpt_error"' EXIT

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
# sources. Keep the model instruction compact: the quoted primary text carries
# the vote-specific detail, while the instruction defines the output contract.
prompt_instructions='Write a politically neutral plain-English guide for someone unfamiliar with the European Parliament. Use only the official sources. A quoted amendment table or report paragraph is primary evidence: use the exact Amendment or paragraph in Vote detail. For a replacement amendment, use the right-hand amended text and say Would replace; use Would add only for a new paragraph or point. Return only one-line JSON with exactly string keys description, yesVote, russia. No Markdown, citations or extra text. Before replying, silently check every character limit and grammar. All values together: at most 500 characters. description: explain what this vote means in the context of its Parent item. Use one compact sentence for an amendment; use two short sentences only for a whole-motion vote. Target 150 characters; hard maximum 220. Name the concrete people, institution, money, rule, right, obligation or objective affected and the practical change. Use plain language; do not merely say text is added, replaced or discussed. For an amendment, state how it changes Parliament’s draft position within the parent motion. For a whole-motion vote, say it approves Parliament’s non-binding position and state its central real-world priorities. If long, remove examples and modifiers, never the actual change. yesVote: start with the grammatical words Would adopt, Would add, Would replace, Would urge, Would approve, or Would speed up; never write Would adopts. Target 110 characters; hard maximum 150. Explain the exact effect of Yes. For an amendment, say the substantive change to Parliament’s draft position. For a whole-motion vote, say it adopts Parliament’s non-binding position and one or two central priorities. A Yes does not itself change EU law, spending or an institution’s mandate. For an urgent decision, say it speeds up the timetable only; it does not decide the underlying rules. If long, remove examples and modifiers, never the actual change. russia: one sentence, maximum 150 characters. Use exactly No supported Russia-related effect is stated. unless the Yes change itself has a concrete causal mechanism that reduces EU collective defence, security, sanctions enforcement, Ukraine support, energy independence, resilience, or coordination against disinformation. Use Potentially: only for that mechanism. Never infer it from the subject, political group, EIB, or a generic restriction alone. Always assess direction: removing a restriction or barrier, expanding defence/security finance, funding weapons, strengthening defence industry, national sovereignty, resilience, or European independence is not a benefit to Russia and must use the exact No supported sentence. If source text says funding must not be diverted to militarisation, excludes militarisation, or prioritises other EIB funding over militarisation, this is an explicit defence-funding restriction: use exactly Potentially: reduced EU defence capability could benefit Russia. Media-literacy rule: the causal test is met only when operative amended wording says that media literacy is not supervised by EU institutions, says Member States retain full control of its design or implementation, or opposes EU educational content through recommendations, funding, or legislation. In those cases russia MUST be exactly: Potentially: limiting EU-level media-literacy coordination could weaken disinformation resilience, benefiting Russia. Do not infer this from criticism of the EU Democracy Shield, institutional determinations, alleged ideological bias, political neutrality, free debate, or marginalisation of criticism alone. Never mention a vote outcome.'
# Russia-benefit warnings require a concrete operational security effect, not a
# broad disagreement about EU education, media policy, or national competence.
prompt_instructions="${prompt_instructions%%russia: one sentence,*}russia: one sentence, maximum 150 characters. Use exactly No supported Russia-related effect is stated. unless the Yes change itself directly and materially reduces EU defence or security capability, sanctions enforcement, Ukraine support, energy security, or a dedicated EU counter-disinformation or enforcement capability. Use Potentially: only for that direct mechanism stated in the official wording; do not infer it from a general political effect or policy disagreement. Education, media literacy, national competence, EU centralisation, political neutrality, free debate, the EU Democracy Shield, or media policy alone are not sufficient, even if they favour national control or could indirectly complicate cooperation. Always assess direction: removing a restriction or barrier, expanding defence or security finance, funding weapons, strengthening defence industry, national sovereignty, resilience, or European independence is not a benefit to Russia and must use the exact No supported sentence. If source text excludes militarisation financing, says funding must not be diverted to militarisation, or prioritises other EIB funding over militarisation, this directly restricts EU defence finance: use exactly Potentially: reduced EU defence capability could benefit Russia. Never mention a vote outcome."

jq -n \
  --arg instructions "$prompt_instructions" \
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
          fallback: (
            ($label | if test("After recital[[:space:]]+[0-9]+"; "i") then capture("After recital[[:space:]]+(?<recital>[0-9]+)"; "i") else {} end) as $after_reci
            | if ($after_reci["recital"] // "") != ""
              and (($sources | map(.label) | index("Amendment text")) == null) then
                {
                  description: "This amendment would add a recital after recital \($after_reci.recital), but its official text is unavailable.",
                  yesVote: "Would add a recital after recital \($after_reci.recital); its official wording is unavailable.",
                  russia: "Official amendment wording is unavailable, so Russia impact cannot be assessed."
                }
              else null end
          ),
          prompt: (
            ($instructions + "\n\n")
           + "Parent item: \($vote.activity_label.en // "")\n"
           + "Vote detail: \($label)\n"
           + "Official sources:\n"
           + ($sources | map("- \(.label): \(.url)") | join("\n"))
            + (if $label | test("Request for an urgent decision"; "i") then
                "\n\nVote-type rule: this is a procedural urgency request, not a vote on the underlying law. description must explain that it speeds up Parliament’s timetable so the named temporary exception can be decided sooner; it does not decide whether that exception takes effect. yesVote must say that Yes approves urgent parliamentary handling. Never say it adopts, changes, extends or derogates the underlying law."
              elif (($label | test("\\bAm\\s+[0-9]+"; "i")) and ([ $sources[] | select(.label == "Amendment text") ] | length == 0)) then
                "\n\nEvidence rule: this amendment wording is absent from the official source bundle. Do not invent its policy content. State only its labelled insertion or replacement location, reproduce that location exactly, and explicitly say the official wording is unavailable."
              else "" end)
         ),
          sources: $sources
        }
    ]
' > "$temporary_candidates"

# DeepSeek does not reliably open linked PDFs. Cache the official amendment
# tables locally and quote their text in the prompt for amendment votes.
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
    echo "Vote explainers: could not extract $amendment_url; it will be retried next update." >&2
  fi
  rm -f "$amendment_pdf" "$amendment_text"
done < <(jq -r '[.[] | .sources[]? | select(.label == "Amendment text") | .url] | unique[]' "$temporary_candidates")

if [[ ! -s "$report_texts_file" ]]; then
  printf '{"version":1,"documents":{}}\n' > "$report_texts_file"
fi

# Paragraph votes are not necessarily amendments. Cache their underlying
# parliamentary reports too, so an answer names the actual paragraph policy
# instead of guessing from the report title or a linked web page.
report_total=$(jq '[.[] | .sources[]? | select(.label == "Parliamentary report") | .url] | unique | length' "$temporary_candidates")
report_current=0
while IFS= read -r report_url; do
  report_current=$((report_current + 1))
  report_document=${report_url##*/}
  report_document=${report_document%_EN.html}
  [[ -n "$report_document" ]] || continue

  if jq -e --arg document "$report_document" '.documents[$document] | (((.text // "") | length > 0) or (.unavailable == true))' "$report_texts_file" > /dev/null; then
    if jq -e --arg document "$report_document" '.documents[$document].unavailable == true' "$report_texts_file" > /dev/null; then
      printf 'Vote explainers: report text %d/%d cached unavailable (%s)\n' "$report_current" "$report_total" "$report_document" >&2
    else
      printf 'Vote explainers: report text %d/%d cached (%s)\n' "$report_current" "$report_total" "$report_document" >&2
    fi
    continue
  fi

  printf 'Vote explainers: report text %d/%d downloading (%s)\n' "$report_current" "$report_total" "$report_document" >&2
  report_pdf=$(mktemp "${TMPDIR:-/tmp}/eu-moles-report-pdf.XXXXXX")
  report_text=$(mktemp "${TMPDIR:-/tmp}/eu-moles-report-text.XXXXXX")
  report_pdf_url="https://data.europarl.europa.eu/distribution/reds_iPlRp/$report_document/${report_document}_en.pdf"
  report_status=$(curl -sS -L --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 --output "$report_pdf" --write-out '%{http_code}' "$report_pdf_url" || true)
  if [[ "$report_status" == "200" ]] &&
    pdftotext -layout "$report_pdf" "$report_text" &&
    [[ -s "$report_text" ]]; then
    jq \
      --arg document "$report_document" \
      --arg url "$report_pdf_url" \
      --rawfile text "$report_text" \
      '.documents[$document] = {url: $url, text: $text}' \
      "$report_texts_file" > "$temporary_report_texts"
    mv -f "$temporary_report_texts" "$report_texts_file"
    temporary_report_texts=$(mktemp "${TMPDIR:-/tmp}/eu-moles-report-texts.XXXXXX")
  elif [[ "$report_status" == "404" ]]; then
    jq \
      --arg document "$report_document" \
      --arg url "$report_pdf_url" \
      '.documents[$document] = {url: $url, unavailable: true}' \
      "$report_texts_file" > "$temporary_report_texts"
    mv -f "$temporary_report_texts" "$report_texts_file"
    temporary_report_texts=$(mktemp "${TMPDIR:-/tmp}/eu-moles-report-texts.XXXXXX")
    echo "Vote explainers: report text $report_document is unavailable (404); caching this result." >&2
  else
    echo "Vote explainers: could not extract $report_pdf_url (HTTP ${report_status:-unknown}); the report link will still be supplied." >&2
  fi
  rm -f "$report_pdf" "$report_text"
done < <(jq -r '[.[] | .sources[]? | select(.label == "Parliamentary report") | .url] | unique[]' "$temporary_candidates")

printf 'Vote explainers: preparing %s response record(s) with official source text and URLs\n' "$(jq 'length' "$temporary_candidates")" >&2
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
    and ((.yesVote // "") | type == "string" and length > 0 and length <= 150)
    and ((.russia // "") | type == "string" and length > 0 and length <= 150)
    and ([.description, .yesVote, .russia] | join(" ") | length <= 500)
    and ([.description, .yesVote, .russia] | join(" ") | test("DeepSeek Web Error|MISSING_HEADER|Some error has occurred|failed to create chat session|^Error:|^Warning:"; "i") | not);
  reduce $candidates[0][] as $candidate (
    {version: 1, items: {}};
    (($existing[0].items[$candidate.id] // {})) as $previous
    | (($candidate.fallback // {})) as $fallback
    | ($fallback != {}) as $has_fallback
    | .items[$candidate.id] = {
        prompt: $candidate.prompt,
        sources: $candidate.sources,
        description: (if $has_fallback then $fallback.description elif $previous.prompt == $candidate.prompt and ($previous | usable_sections) then $previous.description else "" end),
        yesVote: (if $has_fallback then $fallback.yesVote elif $previous.prompt == $candidate.prompt and ($previous | usable_sections) then $previous.yesVote else "" end),
        russia: (if $has_fallback then $fallback.russia elif $previous.prompt == $candidate.prompt and ($previous | usable_sections) then $previous.russia else "" end),
        generatedAt: ($previous.generatedAt // null)
      }
  )
' "$existing_file" > "$temporary_output"
mv -f "$temporary_output" "$output_file"
temporary_output=$(mktemp "${TMPDIR:-/tmp}/eu-moles-vote-explainers.XXXXXX")
[[ "$existing_file" == "$output_file" ]] || rm -f "$existing_file"

tgpt_bin=${TGPT_BIN:-tgpt}
tgpt_provider=${TGPT_PROVIDER:-}
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
# loaded. Reproduce it here: tgpt's DeepSeek Web proof-of-work needs the full
# Homebrew environment, not just an absolute path to node.
for brew_bin in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew; do
  if [[ -x "$brew_bin" ]]; then
    eval "$("$brew_bin" shellenv)"
    break
  fi
done

if ! command -v node > /dev/null 2>&1 && ! command -v bun > /dev/null 2>&1 && ! command -v deno > /dev/null 2>&1; then
  for runtime in /home/linuxbrew/.linuxbrew/opt/node/bin/node /opt/homebrew/opt/node/bin/node; do
    if [[ -x "$runtime" ]]; then
      export PATH="$(dirname "$runtime"):$PATH"
      export DEEPSEEK_WEB_RUNTIME="${DEEPSEEK_WEB_RUNTIME:-$runtime}"
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
    and ((.yesVote // "") | type == "string" and length > 0 and length <= 150)
    and ((.russia // "") | type == "string" and length > 0 and length <= 150)
    and ([.description, .yesVote, .russia] | join(" ") | length <= 500)
  ' <<< "$value" > /dev/null 2>&1 || return 1

  text=$(jq -r '[.description, .yesVote, .russia] | join(" ")' <<< "$value")
  ! grep -Eiq 'DeepSeek Web Error|MISSING_HEADER|Some error has occurred|failed to create chat session|^Error:|^Warning:|\b(passed|failed|adopted|rejected|defeated|voted down|outcome|result|vote tally)\b|did not pass|was not approved' <<< "$text"
}

add_amendment_context() {
  local candidate_value=$1
  local base_prompt=$2
  local amendment_url amendment_document amendment_number amendment_text amendment_row amendment_body

  amendment_url=$(jq -r '[.value.sources[]? | select(.label == "Amendment text") | .url][0] // empty' <<< "$candidate_value")
  [[ -n "$amendment_url" ]] || {
    printf '%s' "$base_prompt"
    return
  }

  amendment_document=${amendment_url##*/}
  amendment_document=${amendment_document%_en.pdf}
  amendment_number=$(jq -r '
    .value.prompt
    | split("\n")
    | map(select(startswith("Vote detail:")))[0]
    | try capture("(?i)\\bAm\\s+(?<number>[0-9]+)") catch {}
    | .number // empty
  ' <<< "$candidate_value")
  amendment_text=$(jq -r --arg document "$amendment_document" '.documents[$document].text // empty' "$amendment_texts_file")
  [[ -n "$amendment_number" && -n "$amendment_text" ]] || {
    echo "Vote explainers: no extracted text is available for $amendment_document" >&2
    return 1
  }

  amendment_row=$(awk -v number="$amendment_number" '
    $0 ~ "^[[:space:]]*Amendment[[:space:]]+" number "([[:space:]]*/[^[:space:]]+)?[[:space:]]*$" { found = 1 }
    found {
      if ($0 ~ /^[[:space:]]*Amendment[[:space:]]+[0-9]+([[:space:]]*\/[^[:space:]]+)?[[:space:]]*$/ && $0 !~ "^[[:space:]]*Amendment[[:space:]]+" number "([[:space:]]*/[^[:space:]]+)?[[:space:]]*$") exit
      print
    }
  ' <<< "$amendment_text")
  [[ -n "$amendment_row" ]] || amendment_row=$amendment_text

  # Tables start after a potentially very long list of signatories. Keep the
  # legislative heading and table, not the names, so the excerpt reaches the
  # actual changed wording.
  amendment_body=$(awk '
    /^[[:space:]]*(Motion for a resolution|Proposal for a regulation|Proposal for a decision|Draft legislative resolution|Report)[[:space:]]*$/ { policy = 1 }
    policy { print }
  ' <<< "$amendment_row")
  [[ -n "$amendment_body" ]] && amendment_row=$amendment_body

  printf '%s\n\nQuoted official Amendment %s (primary evidence): use this text, not the broader report.\n--- amendment text ---\n%s\n--- end amendment text ---' \
    "$base_prompt" "$amendment_number" "${amendment_row:0:3600}"
}

add_report_context() {
  local candidate_value=$1
  local base_prompt=$2
  local report_url report_document paragraph_number report_text paragraph_text

  # An amendment table is more specific evidence than the underlying report.
  if jq -e '[.value.sources[]? | select(.label == "Amendment text")] | length > 0' <<< "$candidate_value" > /dev/null; then
    printf '%s' "$base_prompt"
    return
  fi

  report_url=$(jq -r '[.value.sources[]? | select(.label == "Parliamentary report") | .url][0] // empty' <<< "$candidate_value")
  paragraph_number=$(jq -r '
    .value.prompt
    | split("\n")
    | map(select(startswith("Vote detail:")))[0]
    | try capture("§\\s*(?<number>[0-9]+)") catch {}
    | .number // empty
  ' <<< "$candidate_value")
  [[ -n "$report_url" && -n "$paragraph_number" ]] || {
    printf '%s' "$base_prompt"
    return
  }

  report_document=${report_url##*/}
  report_document=${report_document%_EN.html}
  report_text=$(jq -r --arg document "$report_document" '.documents[$document].text // empty' "$report_texts_file")
  [[ -n "$report_text" ]] || {
    printf '%s' "$base_prompt"
    return
  }

  paragraph_text=$(awk -v number="$paragraph_number" '
    $0 ~ "^[[:space:]]*" number "\\.[[:space:]]" { found = 1 }
    found {
      if ($0 ~ "^[[:space:]]*[0-9]+\\.[[:space:]]" && $0 !~ "^[[:space:]]*" number "\\.[[:space:]]") exit
      print
    }
  ' <<< "$report_text")
  [[ -n "$paragraph_text" ]] || {
    printf '%s' "$base_prompt"
    return
  }

  printf '%s\n\nQuoted official report paragraph %s (primary evidence): use this paragraph, not the broad report title.\n--- report paragraph ---\n%s\n--- end report paragraph ---' \
    "$base_prompt" "$paragraph_number" "${paragraph_text:0:3600}"
}

pending_total=$(jq '[.items[] | select((.description // "") == "" or (.yesVote // "") == "" or (.russia // "") == "")] | length' "$output_file")
explainer_total=$(jq '.items | length' "$output_file")
retry_delay_seconds=${EXPLAINER_RETRY_DELAY_SECONDS:-2}
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
  if ! prompt=$(add_amendment_context "$candidate" "$prompt"); then
    printf 'Vote explainers: response %d/%d awaiting official amendment text (%s)\n' "$response_current" "$explainer_total" "$id" >&2
    continue
  fi
  prompt=$(add_report_context "$candidate" "$prompt")
  answer=""
  printf 'Vote explainers: response %d/%d generating (%s)\n' "$response_current" "$explainer_total" "$id" >&2

  attempt=0
  while :; do
    attempt=$((attempt + 1))
    answer=""
    : > "$temporary_tgpt_error"
    if [[ -n "$tgpt_provider" ]]; then
      answer=$("$tgpt_bin" --provider "$tgpt_provider" -q "$prompt" </dev/null 2>"$temporary_tgpt_error" | compact_text) || answer=""
    else
      answer=$("$tgpt_bin" -q "$prompt" </dev/null 2>"$temporary_tgpt_error" | compact_text) || answer=""
    fi

    if is_valid_explainer_sections "$answer"; then
      break
    fi

    tgpt_error=$(compact_text < "$temporary_tgpt_error")
    if [[ -n "$tgpt_error" ]]; then
      printf 'Vote explainers: attempt %d for %s error: %s\n' "$attempt" "$id" "${tgpt_error:0:600}" >&2
    elif [[ -n "$answer" ]]; then
      printf 'Vote explainers: attempt %d for %s returned invalid output: %s\n' "$attempt" "$id" "${answer:0:600}" >&2
    else
      printf 'Vote explainers: attempt %d for %s returned no output\n' "$attempt" "$id" >&2
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
