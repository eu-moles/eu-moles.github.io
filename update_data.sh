#!/usr/bin/env bash
set -euo pipefail

# Keep the public entry point stable while the update work remains split by
# concern under scripts/.
repository_root=$(cd "$(dirname "$0")" && pwd)

printf '[%s]   0%% (0/2) Updating European Parliament data\n' "$(date +%H:%M:%S)"
"$repository_root/scripts/update-meps.sh"
printf '[%s]  50%% (1/2) Updating plenary vote data\n' "$(date +%H:%M:%S)"
"$repository_root/scripts/update-vote-data.sh"
printf '[%s] 100%% (2/2) Update complete\n' "$(date +%H:%M:%S)"
