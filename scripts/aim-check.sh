#!/usr/bin/env bash
# AIM Identity Check for CI
# Checks if the repository has proper AI agent identity management
# and detects AI tool artifacts in the PR diff.
#
# Environment variables:
#   GITHUB_WORKSPACE  - Repository root (default: .)
#   GITHUB_OUTPUT     - GitHub Actions output file (set automatically by Actions)
#   GITHUB_SHA        - Current commit SHA (set automatically by Actions)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO_ROOT="${GITHUB_WORKSPACE:-.}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info() {
  echo "[aim-check] $*"
}

log_warning() {
  echo "::warning::[aim-check] $*"
}

log_notice() {
  echo "::notice::[aim-check] $*"
}

set_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

# ---------------------------------------------------------------------------
# AIM Initialization Checks
# ---------------------------------------------------------------------------

check_aim_initialized() {
  if [[ -d "${REPO_ROOT}/.opena2a" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

count_identities() {
  local count=0
  if [[ -d "${REPO_ROOT}/.opena2a/identities" ]]; then
    count=$(find "${REPO_ROOT}/.opena2a/identities" -type f -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "$count"
}

check_capability_policy() {
  if [[ -f "${REPO_ROOT}/.opena2a/policy.json" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

count_signatures() {
  local count=0
  if [[ -d "${REPO_ROOT}/.opena2a/signatures" ]]; then
    count=$(find "${REPO_ROOT}/.opena2a/signatures" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "$count"
}

check_governance() {
  if [[ -f "${REPO_ROOT}/SOUL.md" || -f "${REPO_ROOT}/.opena2a/SOUL.md" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# ---------------------------------------------------------------------------
# AI Tool Artifact Detection
# ---------------------------------------------------------------------------

# Detect AI tool artifacts in the git diff (PR changes).
# Returns a count of files with AI tool patterns.
detect_ai_tool_artifacts() {
  local ai_file_count=0
  local ai_file_list=""

  # Patterns that indicate AI tool usage in file paths
  local path_patterns=(
    ".claude/"
    "CLAUDE.md"
    ".cursor/"
    ".cursorrules"
    ".copilot/"
    ".aider"
    "SOUL.md"
    "HEARTBEAT.md"
    ".mcp.json"
    "mcp.json"
    ".mcp/"
  )

  # Get the list of changed files in the PR diff.
  # In a PR context, compare against the base branch.
  # Fall back to HEAD~1 if no merge base is available.
  local changed_files=""

  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    # PR context: compare against base branch
    changed_files=$(git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD" 2>/dev/null || true)
  elif [[ -n "${GITHUB_SHA:-}" ]]; then
    # Push context: compare against parent
    changed_files=$(git diff --name-only HEAD~1 2>/dev/null || true)
  fi

  if [[ -z "$changed_files" ]]; then
    echo "0"
    return
  fi

  for pattern in "${path_patterns[@]}"; do
    local matches
    matches=$(echo "$changed_files" | grep -c "$pattern" 2>/dev/null || true)
    ai_file_count=$((ai_file_count + matches))
  done

  echo "$ai_file_count"
}

# Check git committer metadata for AI tool patterns.
# Returns "true" if any recent commits have AI-associated committer info.
detect_ai_committer() {
  local ai_committer="false"

  # Check recent commits for common AI tool committer patterns
  local committer_patterns=(
    "claude"
    "cursor"
    "copilot"
    "aider"
    "devin"
    "sweep"
    "coderabbit"
  )

  local recent_authors=""
  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    recent_authors=$(git log --format='%an %ae %cn %ce' "origin/${GITHUB_BASE_REF}...HEAD" 2>/dev/null || true)
  else
    recent_authors=$(git log --format='%an %ae %cn %ce' -5 2>/dev/null || true)
  fi

  if [[ -n "$recent_authors" ]]; then
    for pattern in "${committer_patterns[@]}"; do
      if echo "$recent_authors" | grep -qi "$pattern" 2>/dev/null; then
        ai_committer="true"
        break
      fi
    done
  fi

  echo "$ai_committer"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log_info "AIM Identity Check"
  log_info "Repository root: ${REPO_ROOT}"
  echo ""

  # --- AIM status checks ---

  local aim_initialized
  aim_initialized="$(check_aim_initialized)"

  local identity_count
  identity_count="$(count_identities)"

  local has_policy
  has_policy="$(check_capability_policy)"

  local signature_count
  signature_count="$(count_signatures)"

  local has_governance
  has_governance="$(check_governance)"

  # --- AI tool artifact detection ---

  local ai_artifact_count
  ai_artifact_count="$(detect_ai_tool_artifacts)"

  local ai_committer
  ai_committer="$(detect_ai_committer)"

  # --- Report ---

  echo "AIM Identity Status"
  echo "==================="
  echo ""

  local aim_init_detail
  if [[ "$aim_initialized" == "true" ]]; then
    aim_init_detail=".opena2a/ directory present"
  else
    aim_init_detail=".opena2a/ directory not found"
  fi

  local identity_detail
  if [[ "$identity_count" -gt 0 ]]; then
    identity_detail="${identity_count} Ed25519 keypair(s) registered"
  else
    identity_detail="No Ed25519 keypairs registered"
  fi

  local policy_detail
  if [[ "$has_policy" == "true" ]]; then
    policy_detail="policy.json restricts agent access"
  else
    policy_detail="No policy.json restricting agent access"
  fi

  local sig_detail
  if [[ "$signature_count" -gt 0 ]]; then
    sig_detail="${signature_count} tamper-detection signature(s)"
  else
    sig_detail="No tamper-detection signatures"
  fi

  local gov_detail
  if [[ "$has_governance" == "true" ]]; then
    gov_detail="Behavioral safety document present"
  else
    gov_detail="No behavioral safety document"
  fi

  local yes_no_aim="No"
  [[ "$aim_initialized" == "true" ]] && yes_no_aim="Yes"

  local yes_no_policy="Missing"
  [[ "$has_policy" == "true" ]] && yes_no_policy="Present"

  local yes_no_gov="Missing"
  [[ "$has_governance" == "true" ]] && yes_no_gov="Present"

  printf "%-25s %-10s %s\n" "Check" "Status" "Details"
  printf "%-25s %-10s %s\n" "-----" "------" "-------"
  printf "%-25s %-10s %s\n" "AIM Initialized"        "$yes_no_aim"        "$aim_init_detail"
  printf "%-25s %-10s %s\n" "Agent Identities"        "${identity_count} found"  "$identity_detail"
  printf "%-25s %-10s %s\n" "Capability Policy"       "$yes_no_policy"     "$policy_detail"
  printf "%-25s %-10s %s\n" "Config Signatures"       "${signature_count} signed" "$sig_detail"
  printf "%-25s %-10s %s\n" "Governance (SOUL.md)"    "$yes_no_gov"        "$gov_detail"
  echo ""

  # AI tool activity summary
  if [[ "$ai_artifact_count" -gt 0 || "$ai_committer" == "true" ]]; then
    log_info "AI Tool Activity Detected:"
    if [[ "$ai_artifact_count" -gt 0 ]]; then
      log_info "  ${ai_artifact_count} file(s) show patterns consistent with AI-assisted changes"
    fi
    if [[ "$ai_committer" == "true" ]]; then
      log_info "  Commit metadata contains AI tool patterns"
    fi
    if [[ "$aim_initialized" != "true" ]]; then
      log_info "  No verified agent identity associated with changes"
    fi
    echo ""
  fi

  # Recommendation
  if [[ "$aim_initialized" != "true" ]]; then
    log_notice "Run 'npx opena2a init' to set up agent identity management."
  elif [[ "$identity_count" -eq 0 ]]; then
    log_notice "Run 'npx opena2a init' to register agent identities."
  elif [[ "$has_governance" != "true" ]]; then
    log_notice "Create a SOUL.md governance file to define behavioral safety constraints."
  fi

  # --- Set outputs ---

  set_output "aim-initialized"  "$aim_initialized"
  set_output "identity-count"   "$identity_count"
  set_output "has-policy"       "$has_policy"
  set_output "signature-count"  "$signature_count"
  set_output "has-governance"   "$has_governance"
  set_output "ai-artifact-count" "$ai_artifact_count"
  set_output "ai-committer"     "$ai_committer"

  # Build markdown summary for use by post-comment.sh
  local aim_summary=""
  aim_summary+="| AIM Initialized | ${yes_no_aim} | ${aim_init_detail} |"$'\n'
  aim_summary+="| Agent Identities | ${identity_count} found | ${identity_detail} |"$'\n'
  aim_summary+="| Capability Policy | ${yes_no_policy} | ${policy_detail} |"$'\n'
  aim_summary+="| Config Signatures | ${signature_count} signed | ${sig_detail} |"$'\n'
  aim_summary+="| Governance (SOUL.md) | ${yes_no_gov} | ${gov_detail} |"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "aim-summary<<AIM_CHECK_EOF"
      echo "$aim_summary"
      echo "AIM_CHECK_EOF"
    } >> "$GITHUB_OUTPUT"
  fi

  log_info "AIM identity check complete."
}

main "$@"
