#!/usr/bin/env bash
# OpenA2A Trust Gate - Dependency trust verification script
# Checks AI package dependencies against the OpenA2A Registry trust API.
#
# Environment variables:
#   REGISTRY_URL      - OpenA2A Registry API URL (default: https://api.oa2a.org)
#   MIN_TRUST_LEVEL   - Minimum required trust level, 0-4 (default: 3)
#   FAIL_ON_WARNING   - Fail on warning-level packages (default: true)
#   PACKAGE_FILE      - Path to dependency file (auto-detect if empty)
#   CHECK_AIM         - Whether to run AIM identity check (default: true)
#   GITHUB_OUTPUT     - GitHub Actions output file (set automatically by Actions)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REGISTRY_URL="${REGISTRY_URL:-https://api.oa2a.org}"
MIN_TRUST_LEVEL="${MIN_TRUST_LEVEL:-3}"
FAIL_ON_WARNING="${FAIL_ON_WARNING:-true}"
PACKAGE_FILE="${PACKAGE_FILE:-}"
CHECK_AIM="${CHECK_AIM:-true}"
CURL_TIMEOUT=30
BATCH_SIZE=100
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info() {
  echo "[trust-gate] $*"
}

log_error() {
  echo "::error::[trust-gate] $*"
}

log_warning() {
  echo "::warning::[trust-gate] $*"
}

log_notice() {
  echo "::notice::[trust-gate] $*"
}

set_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

# Check that required tools are available.
check_dependencies() {
  local missing=0
  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: ${cmd}"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Dependency file detection
# ---------------------------------------------------------------------------

# Detect dependency files in the current directory.
# Sets the DETECTED_FILES array.
detect_dependency_files() {
  DETECTED_FILES=()

  if [[ -n "$PACKAGE_FILE" ]]; then
    if [[ ! -f "$PACKAGE_FILE" ]]; then
      log_error "Specified package file not found: ${PACKAGE_FILE}"
      exit 1
    fi
    DETECTED_FILES+=("$PACKAGE_FILE")
    return
  fi

  local candidates=(
    "package.json"
    "requirements.txt"
    "pyproject.toml"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      DETECTED_FILES+=("$candidate")
    fi
  done

  if [[ ${#DETECTED_FILES[@]} -eq 0 ]]; then
    log_warning "No supported dependency files found (package.json, requirements.txt, pyproject.toml)."
    log_notice "Trust gate skipped -- no dependency files detected."
    set_output "result" '{"safe":0,"warning":0,"blocked":0,"unknown":0,"packages":[]}'
    set_output "safe-count" "0"
    set_output "warning-count" "0"
    set_output "blocked-count" "0"
    if [[ "$CHECK_AIM" == "true" && -f "${SCRIPT_DIR}/aim-check.sh" ]]; then
      echo ""
      bash "${SCRIPT_DIR}/aim-check.sh"
    fi
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

# Parse package.json and emit one dependency name per line.
parse_package_json() {
  local file="$1"
  jq -r '
    ((.dependencies // {}) | keys[]) ,
    ((.devDependencies // {}) | keys[])
  ' "$file" 2>/dev/null | sort -u
}

# Parse requirements.txt and emit one dependency name per line.
# Strips version specifiers, comments, extras, and blank lines.
parse_requirements_txt() {
  local file="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Remove inline comments
    line="${line%%#*}"
    # Trim whitespace
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # Skip blank lines and option lines (-r, --index-url, etc.)
    [[ -z "$line" ]] && continue
    [[ "$line" == -* ]] && continue
    # Remove extras like package[extra1,extra2]
    line="$(echo "$line" | sed 's/\[.*\]//')"
    # Remove version specifiers (>=, <=, ==, ~=, !=, <, >, ;)
    line="$(echo "$line" | sed 's/[><=!~;].*//')"
    # Remove any trailing whitespace after stripping
    line="$(echo "$line" | sed 's/[[:space:]]*$//')"
    [[ -n "$line" ]] && echo "$line"
  done < "$file" | sort -u
}

# Parse pyproject.toml dependencies and emit one dependency name per line.
# Handles the [project] dependencies array with basic line-by-line parsing.
parse_pyproject_toml() {
  local file="$1"
  local in_deps=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim whitespace
    local trimmed
    trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Detect start of dependencies array
    if [[ "$trimmed" == "dependencies"* && "$trimmed" == *"[" ]]; then
      in_deps=1
      continue
    fi

    # Detect end of array
    if [[ $in_deps -eq 1 && "$trimmed" == *"]"* ]]; then
      in_deps=0
      continue
    fi

    # Detect section headers to stop parsing
    if [[ "$trimmed" == "["* && "$trimmed" != *"=" ]]; then
      in_deps=0
      continue
    fi

    if [[ $in_deps -eq 1 ]]; then
      # Remove quotes and commas
      local dep
      dep="$(echo "$trimmed" | sed 's/[",]//g')"
      # Remove inline comments
      dep="${dep%%#*}"
      # Trim
      dep="$(echo "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$dep" ]] && continue
      # Remove extras
      dep="$(echo "$dep" | sed 's/\[.*\]//')"
      # Remove version specifiers
      dep="$(echo "$dep" | sed 's/[><=!~;].*//')"
      dep="$(echo "$dep" | sed 's/[[:space:]]*$//')"
      [[ -n "$dep" ]] && echo "$dep"
    fi
  done < "$file" | sort -u
}

# ---------------------------------------------------------------------------
# Infer package type from the source file
# ---------------------------------------------------------------------------

infer_package_type() {
  local file="$1"
  local basename
  basename="$(basename "$file")"
  case "$basename" in
    package.json)
      echo "mcp_server"
      ;;
    requirements.txt|pyproject.toml)
      echo "a2a_agent"
      ;;
    *)
      echo "mcp_server"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Registry API
# ---------------------------------------------------------------------------

# Query the trust batch API.
# Arguments: JSON body string
# Outputs: JSON response to stdout
query_trust_batch() {
  local body="$1"
  local response
  local http_code

  local tmpfile
  tmpfile="$(mktemp)"

  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
    --max-time "$CURL_TIMEOUT" \
    --retry 2 \
    --retry-delay 3 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${REGISTRY_URL}/api/v1/trust/batch" 2>/dev/null) || {
    log_warning "API request failed (network error or timeout). Treating all packages as unknown."
    rm -f "$tmpfile"
    echo "{}"
    return
  }

  response="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    log_warning "Registry API returned HTTP ${http_code}. Treating all packages as unknown."
    echo "{}"
    return
  fi

  echo "$response"
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

main() {
  check_dependencies

  log_info "OpenA2A Trust Gate"
  log_info "Registry: ${REGISTRY_URL}"
  log_info "Minimum trust level: ${MIN_TRUST_LEVEL}"
  log_info "Fail on warning: ${FAIL_ON_WARNING}"
  echo ""

  detect_dependency_files

  log_info "Detected dependency files: ${DETECTED_FILES[*]}"
  echo ""

  # Collect all packages as JSON array elements: {"name": "...", "type": "..."}
  local all_packages=()

  for dep_file in "${DETECTED_FILES[@]}"; do
    local pkg_type
    pkg_type="$(infer_package_type "$dep_file")"
    local basename
    basename="$(basename "$dep_file")"

    log_info "Parsing ${basename} (inferred type: ${pkg_type})..."

    local deps=""
    case "$basename" in
      package.json)
        deps="$(parse_package_json "$dep_file")"
        ;;
      requirements.txt)
        deps="$(parse_requirements_txt "$dep_file")"
        ;;
      pyproject.toml)
        deps="$(parse_pyproject_toml "$dep_file")"
        ;;
      *)
        log_warning "Unsupported file format: ${basename}"
        continue
        ;;
    esac

    if [[ -z "$deps" ]]; then
      log_info "  No dependencies found in ${basename}."
      continue
    fi

    local count=0
    while IFS= read -r dep_name; do
      [[ -z "$dep_name" ]] && continue
      all_packages+=("{\"name\":\"${dep_name}\",\"type\":\"${pkg_type}\"}")
      count=$((count + 1))
    done <<< "$deps"

    log_info "  Found ${count} dependencies in ${basename}."
  done

  local total=${#all_packages[@]}

  if [[ $total -eq 0 ]]; then
    log_notice "No dependencies to check."
    set_output "result" '{"safe":0,"warning":0,"blocked":0,"unknown":0,"packages":[]}'
    set_output "safe-count" "0"
    set_output "warning-count" "0"
    set_output "blocked-count" "0"
    if [[ "$CHECK_AIM" == "true" && -f "${SCRIPT_DIR}/aim-check.sh" ]]; then
      echo ""
      bash "${SCRIPT_DIR}/aim-check.sh"
    fi
    exit 0
  fi

  log_info "Total dependencies to check: ${total}"
  echo ""

  # Build batch request body. Split into batches of BATCH_SIZE if needed.
  local safe_count=0
  local warning_count=0
  local blocked_count=0
  local unknown_count=0
  local result_packages="[]"

  local offset=0
  while [[ $offset -lt $total ]]; do
    local batch_items=""
    local end=$((offset + BATCH_SIZE))
    [[ $end -gt $total ]] && end=$total

    for ((i = offset; i < end; i++)); do
      if [[ -n "$batch_items" ]]; then
        batch_items="${batch_items},${all_packages[$i]}"
      else
        batch_items="${all_packages[$i]}"
      fi
    done

    local request_body="{\"packages\":[${batch_items}]}"

    if [[ $total -gt $BATCH_SIZE ]]; then
      log_info "Querying registry (batch $((offset / BATCH_SIZE + 1)), packages $((offset + 1))-${end} of ${total})..."
    else
      log_info "Querying registry for ${total} packages..."
    fi

    local response
    response="$(query_trust_batch "$request_body")"

    # Parse the response.
    # Expected shape: {"results": [{"name": "...", "type": "...", "trustLevel": N, "verdict": "..."}]}
    # or the results may be keyed differently. Handle both array and object responses gracefully.
    local results_array
    results_array="$(echo "$response" | jq -r '.results // .answers // [] | if type == "array" then . else [] end' 2>/dev/null)" || results_array="[]"

    # Process each package in this batch
    for ((i = offset; i < end; i++)); do
      local pkg_name
      pkg_name="$(echo "${all_packages[$i]}" | jq -r '.name')"
      local pkg_type
      pkg_type="$(echo "${all_packages[$i]}" | jq -r '.type')"

      # Look up in results by name
      local trust_level
      trust_level="$(echo "$results_array" | jq -r --arg name "$pkg_name" '
        map(select(.name == $name or .packageName == $name)) | first // empty | .trustLevel // .score // -1
      ' 2>/dev/null)" || trust_level="-1"

      # Determine verdict
      local verdict
      if [[ "$trust_level" == "-1" || "$trust_level" == "null" || -z "$trust_level" ]]; then
        trust_level="-1"
        verdict="unknown"
        unknown_count=$((unknown_count + 1))
      elif [[ "$trust_level" -eq 0 ]]; then
        verdict="blocked"
        blocked_count=$((blocked_count + 1))
      elif [[ "$trust_level" -lt "$MIN_TRUST_LEVEL" ]]; then
        verdict="warning"
        warning_count=$((warning_count + 1))
      else
        verdict="safe"
        safe_count=$((safe_count + 1))
      fi

      # Append to result_packages
      local pkg_result
      pkg_result="{\"name\":\"${pkg_name}\",\"type\":\"${pkg_type}\",\"trustLevel\":${trust_level},\"verdict\":\"${verdict}\"}"
      result_packages="$(echo "$result_packages" | jq --argjson pkg "$pkg_result" '. + [$pkg]')"
    done

    offset=$end
  done

  # ---------------------------------------------------------------------------
  # Summary table
  # ---------------------------------------------------------------------------
  echo ""
  echo "OpenA2A Trust Gate Results"
  echo "========================="
  printf "%-40s %-15s %-13s %s\n" "Package" "Type" "Trust Level" "Verdict"
  printf "%-40s %-15s %-13s %s\n" "-------" "----" "-----------" "-------"

  echo "$result_packages" | jq -r '.[] | [.name, .type, (.trustLevel | tostring), .verdict] | @tsv' | \
    while IFS=$'\t' read -r name type level verdict; do
      local display_level="$level"
      local display_type="$type"
      if [[ "$level" == "-1" ]]; then
        display_level="-"
        display_type="-"
      fi
      printf "%-40s %-15s %-13s %s\n" "$name" "$display_type" "$display_level" "$verdict"
    done

  echo ""
  log_info "Summary: ${safe_count} safe, ${warning_count} warning, ${blocked_count} blocked, ${unknown_count} unknown"
  echo ""

  # ---------------------------------------------------------------------------
  # GitHub Actions annotations
  # ---------------------------------------------------------------------------

  if [[ $blocked_count -gt 0 ]]; then
    local blocked_names
    blocked_names="$(echo "$result_packages" | jq -r '[.[] | select(.verdict == "blocked") | .name] | join(", ")')"
    log_error "Blocked packages detected: ${blocked_names}"
  fi

  if [[ $warning_count -gt 0 ]]; then
    local warning_names
    warning_names="$(echo "$result_packages" | jq -r '[.[] | select(.verdict == "warning") | .name] | join(", ")')"
    log_warning "Packages below trust threshold: ${warning_names}"
  fi

  if [[ $unknown_count -gt 0 ]]; then
    local unknown_names
    unknown_names="$(echo "$result_packages" | jq -r '[.[] | select(.verdict == "unknown") | .name] | join(", ")')"
    log_notice "Packages not found in registry: ${unknown_names}"
  fi

  # ---------------------------------------------------------------------------
  # Set outputs
  # ---------------------------------------------------------------------------

  local result_json
  result_json="$(jq -n \
    --argjson safe "$safe_count" \
    --argjson warning "$warning_count" \
    --argjson blocked "$blocked_count" \
    --argjson unknown "$unknown_count" \
    --argjson packages "$result_packages" \
    '{safe: $safe, warning: $warning, blocked: $blocked, unknown: $unknown, packages: $packages}'
  )"

  # GitHub Actions multiline output
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "result<<TRUST_GATE_EOF"
      echo "$result_json"
      echo "TRUST_GATE_EOF"
    } >> "$GITHUB_OUTPUT"
  fi

  set_output "safe-count" "$safe_count"
  set_output "warning-count" "$warning_count"
  set_output "blocked-count" "$blocked_count"

  # ---------------------------------------------------------------------------
  # Exit decision
  # ---------------------------------------------------------------------------

  if [[ $blocked_count -gt 0 ]]; then
    log_error "Trust gate FAILED: ${blocked_count} blocked package(s) detected."
    exit 1
  fi

  if [[ "$FAIL_ON_WARNING" == "true" && $warning_count -gt 0 ]]; then
    log_error "Trust gate FAILED: ${warning_count} package(s) below minimum trust level ${MIN_TRUST_LEVEL}."
    exit 1
  fi

  log_info "Trust gate PASSED."

  # ---------------------------------------------------------------------------
  # AIM Identity Check (inline, when not run as separate step)
  # ---------------------------------------------------------------------------

  if [[ "$CHECK_AIM" == "true" && -f "${SCRIPT_DIR}/aim-check.sh" ]]; then
    echo ""
    echo "---"
    echo ""
    bash "${SCRIPT_DIR}/aim-check.sh"
  fi

  exit 0
}

main "$@"
