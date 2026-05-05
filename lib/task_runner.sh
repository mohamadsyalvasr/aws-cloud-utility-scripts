#!/bin/bash
# lib/task_runner.sh
# Task execution engine: runs report scripts sequentially or in parallel.
# Requires: RESULT_DIR, log_start, log_success, log_error (from logger.sh)

# Execute a single report task
execute_task() {
    local script_path="$1"
    local run_args=("${@:2}")
    local task_name
    task_name=$(basename "$script_path")

    log_start "🚀 Running ${task_name}..."

    set +e
    if [[ ${#run_args[@]} -gt 0 ]]; then
        "${script_path}" "${run_args[@]}"
    else
        "${script_path}"
    fi
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        log_success "${task_name} finished successfully."
        echo "SUCCESS" > "${RESULT_DIR}/${task_name// /_}.status"
    else
        log_error "${task_name} failed with exit code ${exit_code}."
        echo "FAILED" > "${RESULT_DIR}/${task_name// /_}.status"
    fi
    return $exit_code
}

# Run all tasks in TASKS array
run_tasks() {
    local parallel_enabled="$1"
    local max_parallel="$2"

    if [[ "$parallel_enabled" == "1" ]]; then
        log_start "⏳ Running reports in PARALLEL mode (Max: ${max_parallel})..."
        local PIDS=()
        local TASK_NAMES=()

        for task_info in "${TASKS[@]}"; do
            IFS='|' read -r script_path args <<< "$task_info"

            # Manage parallel limit
            while [[ ${#PIDS[@]} -ge $max_parallel ]]; do
                local NEW_PIDS=()
                for pid in "${PIDS[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        NEW_PIDS+=("$pid")
                    fi
                done
                PIDS=("${NEW_PIDS[@]}")
                if [[ ${#PIDS[@]} -ge $max_parallel ]]; then
                    sleep 1
                fi
            done

            local task_name
            task_name=$(basename "$script_path")
            log_start "  ↳ Starting ${task_name} (background)..."
            execute_task "$script_path" $args > "${RESULT_DIR}/${task_name}.log" 2>&1 &
            PIDS+=($!)
            TASK_NAMES+=("$task_name")
        done

        # Wait for all
        log_start "⏳ Waiting for all parallel tasks to complete..."
        for pid in "${PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done

        # Print collected logs
        log_start "📋 Task output summary:"
        for task_name in "${TASK_NAMES[@]}"; do
            if [[ -f "${RESULT_DIR}/${task_name}.log" ]]; then
                cat "${RESULT_DIR}/${task_name}.log" >&2
            fi
        done
    else
        log_start "⏳ Running reports in SEQUENTIAL mode..."
        for task_info in "${TASKS[@]}"; do
            IFS='|' read -r script_path args <<< "$task_info"
            execute_task "$script_path" $args
        done
    fi

    log_success "All report tasks completed."
}

# Print summary of results
print_summary() {
    echo "--------------------------------------------------"
    echo "             AWS REPORTS SUMMARY                  "
    echo "--------------------------------------------------"
    local total="${#TASKS[@]}"
    local success=0
    local failed=0

    shopt -s nullglob
    for f in "${RESULT_DIR}"/*.status; do
        local content
        content=$(cat "$f")
        if [[ "$content" == "SUCCESS" ]]; then
            success=$((success + 1))
        elif [[ "$content" == "FAILED" ]]; then
            failed=$((failed + 1))
        fi
    done
    shopt -u nullglob

    echo "Total Reports Attempted: $total"
    echo "Successful: $success"
    echo "Failed:     $failed"

    if [[ $failed -gt 0 ]]; then
        echo ""
        echo "Failed Reports List:"
        shopt -s nullglob
        for f in "${RESULT_DIR}"/*.status; do
            if [[ "$(cat "$f")" == "FAILED" ]]; then
                local task_file
                task_file=$(basename "$f" .status)
                echo " - ${task_file//_/ }"
            fi
        done
        shopt -u nullglob
    fi
    echo "--------------------------------------------------"

    if [[ $total -eq 0 ]]; then
        log_error "No reports were selected in config.ini."
    fi
}
