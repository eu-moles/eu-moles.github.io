#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository_root/src"
source "$repository_root/scripts/lib/data-utils.sh"
source "$repository_root/scripts/lib/oeil.sh"
source "$repository_root/scripts/lib/translations.sh"

api="https://data.europarl.europa.eu/api/v2"
cutoff_date=$(date -d '1 month ago' +%F)
voting_dates=$(curl_with_error_url -fsSL "https://data.europarl.europa.eu/distribution/meetings_$(date +%Y)_4_en.csv" |
  sed -nE 's/^MTG-PL-([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' |
  sort -u)
progress_note "Vote data: discovered $(wc -w <<< "$voting_dates") plenary date(s) in the current calendar"

for voting_date in $voting_dates; do
  [[ "$voting_date" == "2026-07-07" ]] || continue
  [[ "$voting_date" < "$cutoff_date" ]] || continue
  stage_total=10
  progress 0 "$stage_total" "Vote data for $voting_date: starting"
  sitting_id="MTG-PL-${voting_date}"
  dir="data/votes/${voting_date}"
  mkdir -p "$dir"
  progress 1 "$stage_total" "Core meeting, vote, activity, and speech records"
  [[ -s "$dir/vote-results.json" ]] || fetch_json "$api/meetings/$sitting_id/vote-results" "$dir/vote-results.json"
  [[ -s "$dir/meeting.json" ]] || fetch_json "$api/meetings/$sitting_id" "$dir/meeting.json"
  [[ -s "$dir/activities.json" ]] || fetch_json "$api/meetings/$sitting_id/activities" "$dir/activities.json"
  [[ -s "$dir/speeches.json" ]] || fetch_json "$api/speeches?sitting-date=$voting_date&activity-type=PLENARY_DEBATE_SPEECH&limit=500&sort-by=video-start-time:asc" "$dir/speeches.json"

  procedures_dir="$dir/procedures"
  mkdir -p "$procedures_dir"
  progress 2 "$stage_total" "Procedure records referenced by the votes"
  while IFS= read -r procedure_id; do
    procedure_file="$procedures_dir/${procedure_id}.json"
    [[ -s "$procedure_file" ]] && continue
    fetch_json "$api/procedures/$procedure_id" "$procedure_file" || { echo "Could not fetch procedure $procedure_id referenced by $sitting_id." >&2; exit 1; }
    sleep 0.5
  done < <(jq -r '
    (.data[] | .inverse_consists_of[]? | objects | .id? // empty | capture("/proc/(?<id>[0-9]{4}-[0-9]{4})$").id),
    (.data[] | .structuredLabel.en? // empty | scan("[0-9]{4}/[0-9]{4}\\([A-Z]+\\)") | capture("(?<year>[0-9]{4})/(?<number>[0-9]{4})\\([A-Z]+\\)") | "\(.year)-\(.number)")
  ' "$dir/vote-results.json" | sort -u)

  oeil_procedures_dir="$dir/oeil-procedures"
  mkdir -p "$oeil_procedures_dir"
  progress 3 "$stage_total" "OEIL procedure pages and document summaries"
  while IFS= read -r -d '' procedure_file; do
    procedure_id=${procedure_file##*/}; procedure_id=${procedure_id%.json}
    oeil_procedure_file="$oeil_procedures_dir/${procedure_id}.html"
    [[ -s "$oeil_procedure_file" ]] && continue
    procedure_reference=$(jq -er '.data[0].label | select(test("^[0-9]{4}/[0-9]{4}\\([A-Z]+\\)$"))' "$procedure_file") || { echo "Could not determine the OEIL reference for procedure $procedure_id." >&2; exit 1; }
    fetch_oeil_procedure "$procedure_reference" "$oeil_procedure_file" || { echo "Could not fetch OEIL procedure page for $procedure_reference." >&2; exit 1; }
    sleep 0.5
  done < <(find "$procedures_dir" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
  extract_oeil_document_summaries "$oeil_procedures_dir" "$dir/oeil-document-summaries.json"

  mkdir -p data/languages
  progress 4 "$stage_total" "Language authority records for parliamentary speeches"
  while IFS= read -r language_uri; do
    language_code="${language_uri##*/}"; language_file="data/languages/${language_code}.xml"
    [[ -s "$language_file" ]] || fetch_language_xml "$language_uri" "$language_file"
  done < <(jq -r '.data[] | .recorded_in_a_realization_of[]? | .originalLanguage[]?' "$dir/speeches.json" | sort -u)

  progress 5 "$stage_total" "Minutes metadata and English voting record"
  minutes_document=$(jq -er '.data[0].recorded_in_a_realization_of[] | select(test("/PV-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | split("/") | last' "$dir/meeting.json")
  [[ -s "$dir/minutes.json" ]] || fetch_json "$api/plenary-session-documents/$minutes_document" "$dir/minutes.json"
  if [[ ! -s "$dir/minutes_en.xml" ]]; then
    minutes_xml_path=$(jq -er '.data[] | .is_realized_by[] | select(.language == "http://publications.europa.eu/resource/authority/language/ENG") | .is_embodied_by[] | select(.media_type == "https://www.iana.org/assignments/media-types/application/xml") | .is_exemplified_by' "$dir/minutes.json")
    fetch_xml "https://data.europarl.europa.eu/$minutes_xml_path" "$dir/minutes_en.xml"
  fi

  progress 6 "$stage_total" "Debate transcript metadata and source text"
  transcript_document=$(jq -er '.data[0].recorded_in_a_realization_of[] | select(test("/CRE-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | split("/") | last' "$dir/meeting.json")
  [[ -s "$dir/transcript.json" ]] || fetch_json "$api/plenary-session-documents/$transcript_document" "$dir/transcript.json"
  if [[ ! -s "$dir/transcript.xml" ]]; then
    transcript_docx_path=$(jq -er '.data[] | .is_realized_by[] | .is_embodied_by[] | select(.media_type == "https://www.iana.org/assignments/media-types/application/vnd.openxmlformats-officedocument.wordprocessingml.document") | .is_exemplified_by' "$dir/transcript.json")
    fetch_docx_document_xml "https://data.europarl.europa.eu/$transcript_docx_path" "$dir/transcript.xml"
  fi

  progress 7 "$stage_total" "Individual roll-call decision records"
  if [[ ! -s "$dir/decisions.json" ]]; then
    decisions_dir="$dir/decisions"; mkdir -p "$decisions_dir"; decision_files=()
    while IFS= read -r decision_id; do
      decision_file="$decisions_dir/${decision_id}.json"
      if [[ ! -s "$decision_file" ]]; then
        fetch_json "$api/events/$decision_id" "$decision_file" || { echo "Could not fetch decision $decision_id for $sitting_id; no incomplete aggregate was saved." >&2; exit 1; }
        sleep 0.1
      fi
      decision_files+=("$decision_file")
    done < <(jq -r '.data[] | .consists_of[]? | split("/") | last' "$dir/vote-results.json")
    ((${#decision_files[@]})) || { echo "No decision IDs were supplied by $dir/vote-results.json." >&2; exit 1; }
    decisions_temporary=$(make_temporary_file "decisions")
    jq -s '{data: [.[].data[]]}' "${decision_files[@]}" > "$decisions_temporary"
    mv "$decisions_temporary" "$dir/decisions.json"
  fi

  progress 8 "$stage_total" "Plain-language vote explainers and official amendment text"
  "$repository_root/scripts/cache-vote-explainers.sh" "$dir"
  progress 9 "$stage_total" "Cached English translations of debate contributions"
  cache_transcript_translations "$voting_date" "$dir"
  progress 10 "$stage_total" "Formatting cached vote data"
  format_data_sources "$dir"
  progress 10 "$stage_total" "Vote data for $voting_date: complete"
  break
done
