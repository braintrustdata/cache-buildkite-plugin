#!/bin/bash

parallel_caches_configured() {
  [ -z "${CACHE_PLUGIN_ENTRY_INDEX:-}" ] &&
    compgen -A variable BUILDKITE_PLUGIN_CACHE_CACHES_ >/dev/null
}

cache_entry_indices() {
  local variable
  while IFS= read -r variable; do
    if [[ "${variable}" =~ ^BUILDKITE_PLUGIN_CACHE_CACHES_([0-9]+)_ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done < <(compgen -A variable BUILDKITE_PLUGIN_CACHE_CACHES_) | sort -nu
}

run_parallel_caches() (
  local hook="$1"
  local operation="${2:-save}"
  local log_dir index pid position status
  local failed=0
  local pids=() indices=() statuses=()

  log_dir=$(mktemp -d)
  trap 'rm -rf "${log_dir}"' EXIT

  if [ "${operation}" = 'restore' ]; then
    echo 'Cache restore summary:'
    while IFS= read -r index; do
      CACHE_PLUGIN_ENTRY_INDEX="${index}" CACHE_PLUGIN_RESTORE_SUMMARY_ONLY=true \
        bash "${hook}" 2>&1 | sed -E 's/^(---|\+\+\+|~~~) //' ||
        echo "Warning: could not summarize cache ${index}; restore will still be attempted"
    done < <(cache_entry_indices)
  fi

  while IFS= read -r index; do
    CACHE_PLUGIN_ENTRY_INDEX="${index}" bash "${hook}" \
      >"${log_dir}/${index}.stdout" 2>"${log_dir}/${index}.stderr" &
    pids+=("$!")
    indices+=("${index}")
  done < <(cache_entry_indices)

  # Wait for every cache before replaying logs and reporting failures.
  for pid in "${pids[@]}"; do
    if wait "${pid}"; then
      statuses+=(0)
    else
      statuses+=("$?")
    fi
  done

  for position in "${!indices[@]}"; do
    index="${indices[${position}]}"
    status="${statuses[${position}]}"
    echo "Cache ${index}:"
    # Keep worker messages in the current Buildkite log group.
    sed -E 's/^(---|\+\+\+|~~~) //' "${log_dir}/${index}.stdout"
    sed -E 's/^(---|\+\+\+|~~~) //' "${log_dir}/${index}.stderr" >&2
    if [ "${status}" -ne 0 ]; then
      echo "Cache ${index} failed with status ${status}" >&2
      failed="${status}"
    fi
  done

  exit "${failed}"
)
