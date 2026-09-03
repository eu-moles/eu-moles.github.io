#!/usr/bin/env bash

# OEIL procedure-page fetching and the document-summary index extracted from
# those cached pages. Requires data-utils.sh to have been sourced first.

fetch_oeil_procedure() {
  local reference="$1"
  local destination="$2"
  local temporary

  temporary=$(make_temporary_file "fetch-oeil")
  progress_note "Downloading OEIL procedure: $reference"
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
