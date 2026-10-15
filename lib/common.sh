#!/bin/bash
# lib/common.sh
# Shared bootstrap library for all report scripts.
#
# Centralizes the boilerplate that was previously copy-pasted across the
# report scripts: logging (via lib/logger.sh), dependency checking, and the
# OUTPUT_DIR / date derivation. Source it near the top of a script, after
# `set -euo pipefail`, using a BASH_SOURCE-resolved path, for example:
#
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
#
# Each script still owns its own REGIONS default
# (ap-southeast-1,ap-southeast-3) and its getopts/usage, because the argument
# sets differ per script. This file deliberately does NOT force a REGIONS
# default.

# Guard against being sourced more than once.
if [[ -n "${_COMMON_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_COMMON_SH_SOURCED=1

# Resolve the repository root from the location of THIS file, so sourcing
# works regardless of the current working directory. lib/common.sh lives in
# <repo>/lib, so the repo root is one level up.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# Shared logging functions: log / log_start / log_success / log_error.
# shellcheck source=lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"

# --- Dependency Check ---
# Verifies that the AWS CLI and jq are installed, plus any extra tool names
# passed as arguments (e.g. "bc" or "python3"). Logs the outcome and exits 1
# if any required tool is missing. Behavior matches the per-script copies it
# replaces.
check_dependencies() {
    local tools=("aws" "jq" "$@")
    log "🔎 Checking dependencies (${tools[*]})..."
    local tool
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log "❌ ${tool} not found. Please install it first."
            exit 1
        fi
    done
    log "✅ Dependencies met."
}

# --- Output directory / date derivation ---
# Sets OUTPUT_DIR, respecting an externally-exported OUTPUT_DIR, otherwise
# defaulting to export/aws-cloud-report-YYYY-MM-DD using the current date.
# This mirrors the old inline block:
#     YEAR=$(date +"%Y"); MONTH=$(date +"%m"); DAY=$(date +"%d")
#     OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
init_output_dir() {
    OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-$(date +%Y-%m-%d)}"
}
