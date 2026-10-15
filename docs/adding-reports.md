# Adding New Reports

This guide explains how to add your own report scripts to the framework.

## Steps

### 1. Create the Script

Place your script in the appropriate directory:
- **Inventory reports:** `script/inventory/your_report.sh`
- **Optimization reports:** `script/optimization/your_optimization_report.sh`
- **Security reports:** `script/security/your_security_report.sh`
- **Compliance reports:** `script/compliance/your_compliance_report.sh`

### 2. Follow the Template

```bash
#!/bin/bash
# your_report.sh
# Description of what this report does.

set -euo pipefail

# Shared helpers: logging (log/log_start/log_success/log_error),
# check_dependencies, and init_output_dir. The BASH_SOURCE-resolved path
# makes sourcing work no matter what the current working directory is.
# For a script under script/<category>/, the repo root is two levels up:
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/your_report.csv"

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-b start_date] [-e end_date] [-f filename] [-h]
EOF
    exit 1
}

# --- Argument Parsing ---
while getopts "r:b:e:f:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        b) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Main ---
# check_dependencies verifies aws + jq (pass extra tool names as arguments,
# e.g. `check_dependencies bc python3`, if your script needs them).
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Write CSV header
printf '"Column1","Column2","Column3","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Your AWS CLI calls here
    DATA=$(aws your-service list-resources --region "$region" --output json 2>/dev/null) || {
        log "  ⚠️ Service not available in $region. Skipping."
        continue
    }

    # Process and write to CSV
    echo "$DATA" | jq -r --arg r "$region" '.Resources[] | [
        .Field1,
        .Field2,
        .Field3,
        $r
    ] | @csv' >> "$OUTPUT_FILE"

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"
```

> **Why source `lib/common.sh`?** It is the shared bootstrap for every report
> script. Sourcing it gives you the logging functions (`log`, `log_start`,
> `log_success`, `log_error` from `lib/logger.sh`), `check_dependencies`
> (verifies `aws` + `jq`, plus any extra tool names you pass), and
> `init_output_dir` (sets `OUTPUT_DIR`, honoring an exported value and
> otherwise defaulting to `export/aws-cloud-report-YYYY-MM-DD`). It also
> exports `REPO_ROOT`. Do not copy-paste a local `log()` or a `date`-based
> `OUTPUT_DIR` block; use the shared helpers instead so behavior stays
> consistent across all scripts.

### 3. Register in `lib/report_registry.sh`

Add one line to the `REPORT_DEFINITIONS` array:

```bash
REPORT_DEFINITIONS=(
    # ... existing entries ...
    "your_key|./script/inventory/your_report.sh|-r -b -e"
    # ...
)
```

**Format:** `"config_key|script_path|required_args"`

- `config_key`: The key name in config.ini
- `script_path`: Path to your script (use the appropriate subdirectory)
- `required_args`: CLI flags your script needs (space-separated)
  - `-r` = regions
  - `-b -e` = date range
  - Empty string `""` = no args needed

### 4. Add to `config.ini`

Add your config key (disabled by default):

```ini
your_key=0
```

### 5. Naming Conventions

| Type | Config Key Prefix | Script Location | Example |
|------|-------------------|-----------------|---------|
| Inventory | (none) | `script/inventory/` | `dynamodb=1` |
| Optimization | `opt_` | `script/optimization/` | `opt_ec2_rightsizing=1` |
| Security | `sec_` | `script/security/` | `sec_iam_audit=1` |
| Compliance | (none) | `script/compliance/` | `tagging_compliance=1` |

The prefix determines which `--mode` includes the script:
- No prefix → `--mode inventory`
- `opt_` → `--mode optimize`
- `sec_` → `--mode security`

## Best Practices

1. **Handle errors gracefully** — Use `2>/dev/null || true` for API calls that might fail
2. **Support all regions** — Some services aren't available everywhere
3. **Add progress indicators** — Use `[X/Y]` format for loops with many items
4. **Write header-only CSV on empty results** — Don't fail, just produce an empty report
5. **Use jq for JSON processing** — Consistent with the rest of the codebase
6. **Log through the shared helpers** -- Use the `log` family of functions provided by `lib/common.sh`; do not define a local `log()`
7. **Handle pagination** — Use `--no-paginate` or implement pagination loops

## Testing Your Script

```bash
# Run standalone (set OUTPUT_DIR and dates)
export OUTPUT_DIR="./test_output"
export START_DATE="2025-08-01"
export END_DATE="2025-08-31"
mkdir -p "$OUTPUT_DIR"
bash script/inventory/your_report.sh -r ap-southeast-1

# Check output
cat test_output/your_report.csv
```
