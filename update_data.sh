#!/usr/bin/env bash
set -euo pipefail

# Keep the public entry point stable while the update work remains split by
# concern under scripts/. Use Bash expansion here so the PATH preflight can
# report a missing `dirname` command instead of failing before it runs.
script_directory=${BASH_SOURCE[0]%/*}
[[ "$script_directory" == "${BASH_SOURCE[0]}" ]] && script_directory=.
repository_root=$(cd "$script_directory" && pwd)

environment_file="$repository_root/.env"

required_commands=(
  awk basename cat curl date dirname find grep head jq mkdir mktemp mv node
  pdftotext rm sed sleep sort stat tr unzip wc wget xmllint
)
missing_commands=()
for required_command in "${required_commands[@]}"; do
  if ! command -v "$required_command" > /dev/null 2>&1; then
    missing_commands+=("$required_command")
  fi
done

if ((${#missing_commands[@]})); then
  log_time='--:--:--'
  if command -v date > /dev/null 2>&1; then
    log_time=$(date +%H:%M:%S)
  fi
  printf '[%s]       Error: required command(s) not available on PATH: %s\n' "$log_time" "${missing_commands[*]}" >&2
  printf '[%s]       Configure PATH so every required binary is available, then run ./update_data.sh again.\n' "$log_time" >&2
  exit 127
fi

if (( $# < 1 || $# > 2 )); then
  printf '[%s]       Usage: ./update_data.sh OLDEST_SITTING_DATE (YYYY-MM-DD) [ONLY_DATE: 0|1]\n' "$(date +%H:%M:%S)" >&2
  exit 64
fi

oldest_sitting_date=$1
only_date=${2:-0}
if ! parsed_date=$(date -d "$oldest_sitting_date" +%F 2>/dev/null) || [[ "$parsed_date" != "$oldest_sitting_date" ]]; then
  printf '[%s]       Error: OLDEST_SITTING_DATE must use YYYY-MM-DD (received %q).\n' "$(date +%H:%M:%S)" "$oldest_sitting_date" >&2
  exit 64
fi
if [[ "$only_date" != 0 && "$only_date" != 1 ]]; then
  printf '[%s]       Error: ONLY_DATE must be 0 or 1 (received %q).\n' "$(date +%H:%M:%S)" "$only_date" >&2
  exit 64
fi

# shellcheck source=scripts/lib/data-utils.sh
source "$repository_root/scripts/lib/data-utils.sh"
if ! load_gemini_environment "$environment_file"; then
  exit 78
fi

if [[ "$only_date" == 1 ]]; then
  printf '[%s]   0%% (0/1) Updating plenary vote data for %s only\n' "$(date +%H:%M:%S)" "$oldest_sitting_date"
  "$repository_root/scripts/update-vote-data.sh" "$oldest_sitting_date" 1
  printf '[%s] 100%% (1/1) Update complete\n' "$(date +%H:%M:%S)"
else
  printf '[%s]   0%% (0/2) Updating European Parliament data\n' "$(date +%H:%M:%S)"
  "$repository_root/scripts/update-meps.sh"
  printf '[%s]  50%% (1/2) Updating plenary vote data\n' "$(date +%H:%M:%S)"
  "$repository_root/scripts/update-vote-data.sh" "$oldest_sitting_date" 0
  printf '[%s] 100%% (2/2) Update complete\n' "$(date +%H:%M:%S)"
fi
