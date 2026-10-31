#!/usr/bin/env bash
# OpenA2A Trust Gate - retired action check
# The action is retired: action.yml runs one step that prints one line naming
# the replacement and exits 1.
#
# The check fails unless action.yml:
#   - declares no inputs and no outputs and carries no ${{ }} expression, so
#     nothing in it reads an input, a context value, a secret or a token;
#   - runs a composite action whose steps list holds exactly one step, with
#     the keys name, shell and run only, shell bash and a literal block script;
#   - gives that step a script whose every command is the echo or exit
#     builtin, with no $, backquote, redirection, pipe, & or ;, so the script
#     reads no variable and starts no program.
# It then runs the step as the runner runs a composite bash step
# (bash --noprofile --norc -eo pipefail <file>), in an empty environment whose
# PATH names an empty directory, and fails unless the step exits 1 and prints
# exactly one line that carries the replacement URL and names the audit
# command.
#
# Usage: bash tests/action-retired.sh [path/to/action.yml]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-$repo_root/action.yml}"
replacement_url="https://github.com/opena2a-org/ai-trust#gate-a-projects-ai-dependencies-in-ci"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$action" ] || fail "$action not found"

if grep -qE '^inputs:' "$action"; then
  fail "$action declares inputs"
fi
if grep -qE '^outputs:' "$action"; then
  fail "$action declares outputs"
fi
if grep -qF '${{' "$action"; then
  fail "$action carries a \${{ }} expression"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
step_file="$work/step.sh"
: > "$step_file"

# Reads the runs block of action.yml. Prints "using <value>", one "step <n>"
# line per step, "key <n> <key>" per key of a step, "shell <n> <value>",
# "style <n> <indicator>" for a block script and "unparsed <n> <line>" for a
# line inside the steps list that is neither a key of a step nor part of its
# block script. Writes the script of step 1 to the file named by script.
parser='
function indent_of(s,    t) { t = s; sub(/[^ ].*$/, "", t); return length(t) }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unquote(s,    a, b) {
  s = trim(s)
  a = substr(s, 1, 1); b = substr(s, length(s), 1)
  if (length(s) >= 2 && a == b && (a == "\"" || a == sq)) s = substr(s, 2, length(s) - 2)
  return s
}
BEGIN { top = ""; runs_indent = -1; in_steps = 0; n = 0; key_indent = -1; in_block = 0 }
{
  line = $0
  if (in_block) {
    if (line ~ /^[ ]*$/) { if (n == 1) print "" > script; next }
    if (indent_of(line) > block_parent) {
      if (block_indent < 0) block_indent = indent_of(line)
      if (n == 1) print substr(line, block_indent + 1) > script
      next
    }
    in_block = 0
  }
  if (line ~ /^[ ]*$/ || line ~ /^[ ]*#/) next
  i = indent_of(line)
  if (i == 0) { top = line; sub(/:.*$/, "", top); in_steps = 0; next }
  if (top != "runs") next
  if (runs_indent < 0) runs_indent = i
  if (i == runs_indent && line !~ /^[ ]*- /) {
    k = trim(line); sub(/:.*$/, "", k)
    in_steps = (k == "steps")
    if (k == "using") { v = line; sub(/^[^:]*:/, "", v); print "using " unquote(v) }
    next
  }
  if (!in_steps) next
  if (line ~ /^[ ]*- /) {
    n++
    print "step " n
    key_indent = i + 2
    rest = substr(line, i + 3)
  } else if (i == key_indent) {
    rest = substr(line, i + 1)
  } else {
    print "unparsed " n " " line
    next
  }
  k = rest; sub(/:.*$/, "", k); k = trim(k)
  v = ""
  if (index(rest, ":") > 0) v = trim(substr(rest, index(rest, ":") + 1))
  print "key " n " " k
  if (k == "shell") print "shell " n " " unquote(v)
  if (k == "run") {
    if (v ~ /^[|>][-+0-9]*$/) {
      print "style " n " " v
      in_block = 1; block_parent = key_indent; block_indent = -1
    } else if (n == 1) {
      print unquote(v) > script
    }
  }
}
'
summary="$(awk -v script="$step_file" -v sq="'" "$parser" "$action")" || fail "could not read $action"

# field <name>: the summary lines that start with <name>, without the name.
field() {
  printf '%s\n' "$summary" | awk -v want="$1" '$1 == want { $1 = ""; sub(/^ /, ""); print }'
}

using="$(field using)"
[ "$using" = "composite" ] || fail "$action runs.using is '$using', not composite"

steps="$(field step | wc -l | tr -d ' ')"
[ "$steps" = "1" ] || fail "$action runs.steps holds $steps steps, not 1"

unparsed="$(field unparsed | awk 'NR == 1 { $1 = ""; sub(/^ /, ""); print }')"
[ -z "$unparsed" ] || fail "$action has a line in its step that is not a key of the step: '$unparsed'"

has_run=0
for key in $(field key | awk '{ print $2 }'); do
  case "$key" in
    run) has_run=1 ;;
    name|shell) ;;
    *) fail "the step in $action has the key '$key'; only name, shell and run are allowed" ;;
  esac
done
[ "$has_run" -eq 1 ] || fail "the step in $action has no run key"

shell="$(field shell | awk '{ print $2 }')"
[ "$shell" = "bash" ] || fail "the step in $action uses shell '$shell', not bash"

style="$(field style | awk '{ print $2 }')"
case "$style" in
  '|'|'|-') ;;
  *) fail "the step in $action gives run as '$style'; use a literal block (run: |)" ;;
esac

[ -s "$step_file" ] || fail "the step in $action has an empty script"

if grep -qE '[$`<>|&;\\]' "$step_file"; then
  fail "the step script in $action carries \$, a backquote, a redirection, a pipe, & or ;"
fi
while IFS= read -r cmd || [ -n "$cmd" ]; do
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  case "$cmd" in
    ''|'#'*) ;;
    echo|'echo '*|exit|'exit '*) ;;
    *) fail "the step script in $action runs '${cmd%% *}'; only the echo and exit builtins are allowed" ;;
  esac
done < "$step_file"

mkdir -p "$work/empty-path" "$work/home" "$work/cwd"
set +e
(
  cd "$work/cwd" &&
    env -i PATH="$work/empty-path" HOME="$work/home" \
      "$BASH" --noprofile --norc -eo pipefail "$step_file"
) > "$work/out" 2>&1
status=$?
set -e

output="$(cat "$work/out")"
[ "$status" -eq 1 ] || fail "the step exited $status, not 1; it printed: $output"

lines="$(awk 'END { print NR }' "$work/out")"
[ "$lines" -eq 1 ] || fail "the step printed $lines lines, not 1: $output"

grep -qF "$replacement_url" "$work/out" || fail "the step's line does not carry $replacement_url: $output"
grep -qw 'audit' "$work/out" || fail "the step's line does not name the audit command: $output"

echo "PASS: $action runs one step that exits 1 and prints one line naming $replacement_url"
