#!/usr/bin/env bash
# The analysis build: InvariantGlobalization off, so the culture analyzers
# (CA1304, CA1305, CA1310, CA1311) run, and every warning is an error.
#   BUILD_ROOT=<dir>  build products, never inside the plugin folder
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${BUILD_ROOT:-$HOME/.cache/omanotes-build}"
cd "$root/db"
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
  dotnet build -c Release -p:InvariantGlobalization=false -p:BuildRoot="$work/analyze/" "$@"
