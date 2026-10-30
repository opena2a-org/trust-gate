#!/usr/bin/env bash
# Post Trust Gate results as a PR comment.
# Updates an existing comment if one from a previous run exists.
#
# Environment variables:
#   GH_TOKEN          - GitHub token for API access
#   GITHUB_REPOSITORY - owner/repo (set by Actions)
#   GITHUB_REF        - refs/pull/<number>/merge (set by Actions for PRs)
#   GITHUB_EVENT_NAME - Event type (set by Actions)
#   TRUST_RESULT      - JSON result from trust-check step
#   AIM_INITIALIZED   - Whether AIM is initialized (from aim-check)
#   AIM_SUMMARY       - Markdown table rows for AIM status (from aim-check)
#   IDENTITY_COUNT    - Number of agent identities (from aim-check)
#   HAS_GOVERNANCE    - Whether SOUL.md exists (from aim-check)
#   AI_ARTIFACT_COUNT - Number of AI tool artifact files (from aim-check)
#   AI_COMMITTER      - Whether AI committer patterns detected (from aim-check)
#   SAFE_COUNT        - Trust check safe count
#   WARNING_COUNT     - Trust check warning count
#   BLOCKED_COUNT     - Trust check blocked count

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

COMMENT_MARKER="<!-- trust-gate-comment -->"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info() {
  echo "[post-comment] $*"
}

log_warning() {
  echo "::warning::[post-comment] $*"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

if [[ -z "${GH_TOKEN:-}" ]]; then
  log_warning "GH_TOKEN not set. Skipping PR comment."
  exit 0
fi

if ! command -v gh &>/dev/null; then
  log_warning "'gh' CLI not found. Skipping PR comment."
  exit 0
fi

if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
  log_info "Not a pull_request event (${GITHUB_EVENT_NAME:-unknown}). Skipping PR comment."
  exit 0
fi

# Extract PR number from GITHUB_REF (refs/pull/<number>/merge)
PR_NUMBER=""
if [[ "${GITHUB_REF:-}" =~ refs/pull/([0-9]+)/ ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
fi

if [[ -z "$PR_NUMBER" ]]; then
  log_warning "Could not determine PR number from GITHUB_REF (${GITHUB_REF:-}). Skipping PR comment."
  exit 0
fi

# ---------------------------------------------------------------------------
# Build comment body
# ---------------------------------------------------------------------------

SAFE_COUNT="${SAFE_COUNT:-0}"
WARNING_COUNT="${WARNING_COUNT:-0}"
BLOCKED_COUNT="${BLOCKED_COUNT:-0}"
AIM_INITIALIZED="${AIM_INITIALIZED:-false}"
IDENTITY_COUNT="${IDENTITY_COUNT:-0}"
HAS_GOVERNANCE="${HAS_GOVERNANCE:-false}"
AI_ARTIFACT_COUNT="${AI_ARTIFACT_COUNT:-0}"
AI_COMMITTER="${AI_COMMITTER:-false}"
AIM_SUMMARY="${AIM_SUMMARY:-}"

# Determine trust gate status
TRUST_STATUS="PASS"
if [[ "$BLOCKED_COUNT" -gt 0 ]]; then
  TRUST_STATUS="FAIL"
elif [[ "$WARNING_COUNT" -gt 0 ]]; then
  TRUST_STATUS="WARNING"
fi

# Build the comment
COMMENT_BODY="${COMMENT_MARKER}
## OpenA2A Trust Gate

**Status:** ${TRUST_STATUS}

### Dependency Trust Summary

| Metric | Count |
|--------|-------|
| Safe | ${SAFE_COUNT} |
| Warning | ${WARNING_COUNT} |
| Blocked | ${BLOCKED_COUNT} |

### AI Agent Identity Status

| Check | Status | Details |
|-------|--------|---------|
${AIM_SUMMARY}"

# Add AI tool activity section if relevant
if [[ "$AI_ARTIFACT_COUNT" -gt 0 || "$AI_COMMITTER" == "true" ]]; then
  COMMENT_BODY+="

**AI Tool Activity in This PR:**"
  if [[ "$AI_ARTIFACT_COUNT" -gt 0 ]]; then
    COMMENT_BODY+="
- ${AI_ARTIFACT_COUNT} file(s) show patterns consistent with AI-assisted changes"
  fi
  if [[ "$AI_COMMITTER" == "true" ]]; then
    COMMENT_BODY+="
- Commit metadata contains AI tool patterns"
  fi
  if [[ "$AIM_INITIALIZED" != "true" ]]; then
    COMMENT_BODY+="
- No verified agent identity associated with changes"
  fi
fi

# Add recommendation
if [[ "$AIM_INITIALIZED" != "true" ]]; then
  COMMENT_BODY+="

**Recommendation:** Run \`npx opena2a init\` to set up agent identity management."
elif [[ "$IDENTITY_COUNT" -eq 0 ]]; then
  COMMENT_BODY+="

**Recommendation:** Run \`npx opena2a init\` to register agent identities."
elif [[ "$HAS_GOVERNANCE" != "true" ]]; then
  COMMENT_BODY+="

**Recommendation:** Create a SOUL.md governance file to define behavioral safety constraints."
fi

COMMENT_BODY+="

---
*Posted by [OpenA2A Trust Gate](https://github.com/opena2a-org/trust-gate)*"

# ---------------------------------------------------------------------------
# Post or update comment
# ---------------------------------------------------------------------------

log_info "Posting Trust Gate results to PR #${PR_NUMBER}..."

# The identity this run posts as, read once. A token that may read /user posts
# as its own login; the default github.token is refused /user and posts as the
# Actions bot.
POSTER=$(gh api user --jq .login 2>/dev/null) || POSTER='github-actions[bot]'
LOGIN_PATTERN='^[A-Za-z0-9-]+(\[bot\])?$'
if [[ ! "$POSTER" =~ $LOGIN_PATTERN ]]; then
  POSTER='github-actions[bot]'
fi

# Look, across every page of the PR's comments, for the newest Trust Gate
# comment that identity posted. A marker comment posted by anyone else is
# never updated.
OWN_COMMENT_ID=""
OWN_COMMENT_ID=$(gh api --paginate \
  "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.login == \"${POSTER}\" and (.body | contains(\"${COMMENT_MARKER}\"))) | .id" \
  2>/dev/null | sort -n | tail -n 1 || true)

UPDATED="false"
if [[ -n "$OWN_COMMENT_ID" ]]; then
  # Update the Action's own comment
  if gh api \
    "repos/${GITHUB_REPOSITORY}/issues/comments/${OWN_COMMENT_ID}" \
    -X PATCH \
    -f body="$COMMENT_BODY" \
    --silent 2>/dev/null; then
    UPDATED="true"
    log_info "Updated existing comment (ID: ${OWN_COMMENT_ID})."
  else
    log_warning "Failed to update existing comment (ID: ${OWN_COMMENT_ID}). Posting a new comment."
  fi
fi

if [[ "$UPDATED" != "true" ]]; then
  # Create new comment: none of the Action's own exists, or its update failed
  if gh api \
    "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
    -f body="$COMMENT_BODY" \
    --silent 2>/dev/null; then
    log_info "Posted new comment on PR #${PR_NUMBER}."
  else
    log_warning "Failed to post comment on PR #${PR_NUMBER}."
  fi
fi
