#!/usr/bin/env bash
# OpenA2A Trust Gate - results comment author check
# Runs scripts/post-comment.sh against a stub `gh` that serves fixture comment
# lists and records every call. Checks that the script reads the identity it
# posts as once, updates a results comment only when that identity posted it,
# finds that comment across every page of the pull request's comments, and
# posts a new comment when there is none or when the update fails.
#
# The stub is placed first on PATH and no case runs unless `command -v gh`
# resolves to it. GH_HOST names a host under the reserved .invalid domain, so
# a gh other than the stub has no GitHub host to reach.
#
# Usage: bash tests/post-comment-author.sh [path/to/post-comment.sh]
# Needs: jq (the stub applies the script's --jq filters with it).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${1:-$repo_root/scripts/post-comment.sh}"

REPO="acme/widgets"
PR=7
MARKER="<!-- trust-gate-comment -->"
BOT="github-actions[bot]"

fail_setup() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$script" ] || fail_setup "$script not found"
command -v jq >/dev/null 2>&1 || fail_setup "jq not found; the stub gh applies --jq filters with it"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Stub gh: serves `gh api` only. `GET user` answers with $STUB_LOGIN, or is
# refused when it is unset, as /user refuses the default github.token. The
# comment list serves $STUB_FIXTURES/page-N.json: every page with --paginate,
# the first page without it. A PATCH fails when $STUB_PATCH_FAILS is 1, and
# any route GitHub does not document answers 404. Every call is recorded in
# $STUB_LOG as "METHOD PATH".
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

record() { printf '%s\n' "$*" >> "$STUB_LOG"; }

if [ "${1:-}" != "api" ]; then
  record "UNSERVED gh $*"
  echo "stub gh: only 'gh api' is served" >&2
  exit 64
fi
shift

method="" path="" jq_filter="" paginate=0 has_field=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method|-q|--jq|-f|--raw-field|-F|--field)
      if [ $# -lt 2 ]; then
        record "UNSERVED flag $1 without a value"
        exit 64
      fi
      case "$1" in
        -X|--method) method="$2" ;;
        -q|--jq) jq_filter="$2" ;;
        *) has_field=1 ;;
      esac
      shift 2 ;;
    --paginate) paginate=1; shift ;;
    --silent) shift ;;
    -*)
      record "UNSERVED flag $1"
      echo "stub gh: flag $1 is not served" >&2
      exit 64 ;;
    *)
      if [ -n "$path" ]; then
        record "UNSERVED argument $1"
        exit 64
      fi
      path="${1#/}"
      shift ;;
  esac
done

if [ -z "$method" ]; then
  if [ "$has_field" -eq 1 ]; then method=POST; else method=GET; fi
fi
if [ "$paginate" -eq 1 ]; then
  record "$method $path (paginate)"
else
  record "$method $path"
fi

case "$method $path" in
  "GET user")
    if [ -z "${STUB_LOGIN:-}" ]; then
      echo "gh: Resource not accessible by integration (HTTP 403)" >&2
      exit 1
    fi
    jq -n -r --arg login "$STUB_LOGIN" "{login: \$login} | ${jq_filter:-.}" ;;
  "GET repos/$STUB_REPO/issues/$STUB_PR/comments")
    n=1
    while [ -f "$STUB_FIXTURES/page-$n.json" ]; do
      if [ -n "$jq_filter" ]; then
        jq -r "$jq_filter" "$STUB_FIXTURES/page-$n.json" || exit 1
      else
        cat "$STUB_FIXTURES/page-$n.json"
      fi
      [ "$paginate" -eq 1 ] || break
      n=$((n + 1))
    done ;;
  "PATCH repos/$STUB_REPO/issues/comments/"*)
    if [ "${STUB_PATCH_FAILS:-}" = "1" ]; then
      echo "gh: Resource not accessible by integration (HTTP 403)" >&2
      exit 1
    fi
    if ! jq -e -s --arg id "${path##*/}" 'add // [] | any(.[]; (.id | tostring) == $id)' \
        "$STUB_FIXTURES"/page-*.json >/dev/null 2>&1; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi ;;
  "POST repos/$STUB_REPO/issues/$STUB_PR/comments")
    : ;;
  *)
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"

PATH="$work/bin:$PATH"
export PATH
export GH_HOST="stub.invalid"
unset STUB_LOGIN STUB_PATCH_FAILS

resolved="$(command -v gh || true)"
[ "$resolved" = "$work/bin/gh" ] ||
  fail_setup "gh resolves to '${resolved:-nothing}', not the stub $work/bin/gh; no case was run"

# comment <id> <login> <body>: one issue comment as the API returns it.
comment() {
  jq -n --argjson id "$1" --arg login "$2" --arg body "$3" \
    '{id: $id, user: {login: $login}, body: $body}'
}

# new_case <name>: prints a fresh fixture directory for one case.
new_case() {
  mkdir -p "$work/$1"
  printf '%s\n' "$work/$1"
}

# run_case <dir> [VAR=value ...]: runs the script with the stub serving <dir>.
run_case() {
  local dir="$1" status=0
  shift
  : > "$dir/calls.log"
  env STUB_LOG="$dir/calls.log" STUB_FIXTURES="$dir" STUB_REPO="$REPO" STUB_PR="$PR" \
    GH_TOKEN=stub GITHUB_REPOSITORY="$REPO" GITHUB_REF="refs/pull/$PR/merge" \
    GITHUB_EVENT_NAME=pull_request "$@" \
    bash "$script" > "$dir/output.log" 2>&1 || status=$?
  echo "$status" > "$dir/status"
}

problems=""
total=0
failed=0

# expect <dir> <call> <count>: the call was recorded exactly <count> times.
expect() {
  local n
  n="$(grep -c -x -F "$2" "$1/calls.log" || true)"
  [ "$n" -eq "$3" ] || problems="${problems}
  expected $3 x '$2', saw $n"
}

# expect_patches <dir> <count>: <count> PATCH calls were recorded in total.
expect_patches() {
  local n
  n="$(grep -c '^PATCH ' "$1/calls.log" || true)"
  [ "$n" -eq "$2" ] || problems="${problems}
  expected $2 PATCH call(s) in total, saw $n"
}

# finish_case <name> <dir>: reports the case and prints its calls on failure.
finish_case() {
  local status
  status="$(cat "$2/status")"
  [ "$status" -eq 0 ] || problems="${problems}
  post-comment.sh exited $status"
  total=$((total + 1))
  if [ -z "$problems" ]; then
    echo "PASS: $1"
  else
    failed=$((failed + 1))
    echo "FAIL: $1${problems}"
    sed 's/^/  recorded: /' "$2/calls.log"
  fi
  problems=""
}

results="$MARKER
## OpenA2A Trust Gate"
create="POST repos/$REPO/issues/$PR/comments"

# (a) The only marker comment was posted by someone else: it is ignored and the
# Action posts its own.
dir="$(new_case a)"
comment 101 someone "$results" | jq -s . > "$dir/page-1.json"
run_case "$dir"
expect "$dir" "GET user" 1
expect_patches "$dir" 0
expect "$dir" "$create" 1
finish_case "(a) a marker comment by someone else is ignored and the Action posts its own" "$dir"

# (b) Default token: /user is refused, so the Action posts as the Actions bot.
# Its own marker comment and an older one by someone: the PATCH targets its own.
dir="$(new_case b-default-token)"
{ comment 201 someone "$results"; comment 202 "$BOT" "$results"; } | jq -s . > "$dir/page-1.json"
run_case "$dir"
expect "$dir" "GET user" 1
expect_patches "$dir" 1
expect "$dir" "PATCH repos/$REPO/issues/comments/202" 1
expect "$dir" "$create" 0
finish_case "(b) default token: the PATCH targets the Action's own comment, not someone's older one" "$dir"

# (b) Personal token: /user answers, so the Action posts as that login. The
# PATCH targets that login's comment, not an older one by someone and not a
# newer one by the Actions bot.
dir="$(new_case b-personal-token)"
{
  comment 301 someone "$results"
  comment 302 maintainer-one "$results"
  comment 303 "$BOT" "$results"
} | jq -s . > "$dir/page-1.json"
run_case "$dir" STUB_LOGIN=maintainer-one
expect "$dir" "GET user" 1
expect_patches "$dir" 1
expect "$dir" "PATCH repos/$REPO/issues/comments/302" 1
expect "$dir" "$create" 0
finish_case "(b) personal token: the PATCH targets the comment that login posted" "$dir"

# (c) The update of the Action's own comment fails: a new comment is posted.
dir="$(new_case c)"
comment 401 "$BOT" "$results" | jq -s . > "$dir/page-1.json"
run_case "$dir" STUB_PATCH_FAILS=1
expect "$dir" "GET user" 1
expect "$dir" "PATCH repos/$REPO/issues/comments/401" 1
expect "$dir" "$create" 1
finish_case "(c) when the update of its own comment fails, the Action posts a new comment" "$dir"

# (d) Control: no marker comment on the pull request: one new comment.
dir="$(new_case d)"
{ comment 501 someone "Looks good."; comment 502 "$BOT" "Another workflow's note."; } |
  jq -s . > "$dir/page-1.json"
run_case "$dir"
expect_patches "$dir" 0
expect "$dir" "$create" 1
finish_case "(d) control: with no marker comment the Action posts one comment" "$dir"

# (e) The Action's own comment is on the second page of 30: found and updated.
dir="$(new_case e)"
for i in $(seq 1 30); do
  comment "$((600 + i))" reviewer "Review note $i."
done | jq -s . > "$dir/page-1.json"
comment 631 "$BOT" "$results" | jq -s . > "$dir/page-2.json"
run_case "$dir"
expect "$dir" "GET user" 1
expect_patches "$dir" 1
expect "$dir" "PATCH repos/$REPO/issues/comments/631" 1
expect "$dir" "$create" 0
finish_case "(e) the Action's own comment on the second page of 30 is found and updated" "$dir"

# (f) Two of the Action's own marker comments, each followed by one by someone:
# the newest of its own is the one updated.
dir="$(new_case f)"
{
  comment 701 "$BOT" "$results"
  comment 702 someone "$results"
  comment 703 "$BOT" "$results"
  comment 704 someone "$results"
} | jq -s . > "$dir/page-1.json"
run_case "$dir"
expect "$dir" "GET user" 1
expect_patches "$dir" 1
expect "$dir" "PATCH repos/$REPO/issues/comments/703" 1
expect "$dir" "$create" 0
finish_case "(f) the newest of the Action's own marker comments is the one updated" "$dir"

echo "$((total - failed)) of $total cases passed"
[ "$failed" -eq 0 ] || exit 1
