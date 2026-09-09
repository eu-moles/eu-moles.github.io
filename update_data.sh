#!/usr/bin/env bash
set -euo pipefail

# Keep the public entry point stable while the update work remains split by
# concern under scripts/. Use Bash expansion here so the PATH preflight can
# report a missing `dirname` command instead of failing before it runs.
script_directory=${BASH_SOURCE[0]%/*}
[[ "$script_directory" == "${BASH_SOURCE[0]}" ]] && script_directory=.
repository_root=$(cd "$script_directory" && pwd)

required_commands=(
  awk basename cat curl date dirname find grep head jq mkdir mktemp mv node
  pdftotext rm sed sleep sort stat tgpt tr unzip wc wget xmllint
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

printf '[%s]   0%% (0/2) Updating European Parliament data\n' "$(date +%H:%M:%S)"
"$repository_root/scripts/update-meps.sh"
printf '[%s]  50%% (1/2) Updating plenary vote data\n' "$(date +%H:%M:%S)"
"$repository_root/scripts/update-vote-data.sh"
printf '[%s] 100%% (2/2) Update complete\n' "$(date +%H:%M:%S)"
