#!/usr/bin/env bash
# OpenA2A Trust Gate - README title check
# Fails when the README page title is not the first line, a line of its own
# followed by a blank line, or when the title text is joined onto another
# line, as it once was onto the ecosystem header.
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

# The header block opens with the title: line 1 is exactly the title.
first_line=$(head -n 1 "$README")
[ "$first_line" = "$TITLE" ] || fail "line 1 of $README is not exactly '$TITLE'"

# The title text appears on no other line, so it is never joined onto another
# header part such as the ecosystem header.
glued=$(grep -nF "$TITLE" "$README" | grep -vxF "1:$TITLE" | head -n 1 || true)
[ -z "$glued" ] || fail "line ${glued%%:*} of $README carries '$TITLE' joined to other text"

# A blank line separates the title from the next header part.
[ -z "$(sed -n '2p' "$README")" ] || fail "line 2 of $README is not blank after '$TITLE'"

echo "PASS: $README line 1 is '$TITLE' followed by a blank line"
