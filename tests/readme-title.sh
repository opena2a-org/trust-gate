#!/usr/bin/env bash
# OpenA2A Trust Gate - README title check
# Fails when the README page title is not a line of its own after a blank
# line, for example when it is joined onto the ecosystem header on line 1.
#
# Usage: bash tests/readme-title.sh [path/to/README.md]

set -euo pipefail

README="${1:-$(dirname "$0")/../README.md}"
TITLE="# OpenA2A Trust Gate"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$README" ] || fail "$README not found"

# Line 1 is the ecosystem header; the title must not share it.
first_line=$(head -n 1 "$README")
case "$first_line" in
  *"$TITLE"*) fail "line 1 of $README carries '$TITLE' after the ecosystem header" ;;
esac

# The title must be a whole line, preceded by a blank line.
title_line=$(grep -nxF "$TITLE" "$README" | head -n 1 | cut -d: -f1 || true)
[ -n "$title_line" ] || fail "no line of $README is exactly '$TITLE'"

if [ "$title_line" -eq 1 ] || [ -n "$(sed -n "$((title_line - 1))p" "$README")" ]; then
  fail "line $title_line of $README ('$TITLE') does not follow a blank line"
fi

echo "PASS: $README line $title_line is '$TITLE' after a blank line"
