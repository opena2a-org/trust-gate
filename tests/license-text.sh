#!/usr/bin/env bash
# Checks that LICENSE is the Apache License 2.0 text as published at
# https://www.apache.org/licenses/LICENSE-2.0.txt, with only the appendix
# copyright line filled in.
#
# The check needs no network access: it restores the appendix placeholder
# ("Copyright [yyyy] [name of copyright owner]") and compares the SHA-256
# of the result with the SHA-256 of the published text.
#
# Usage:
#   tests/license-text.sh          # checks LICENSE in the repository root
#   tests/license-text.sh <file>   # checks another file
#
# Exit status: 0 when the text matches, 1 when it does not.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
license_file="${1:-$repo_root/LICENSE}"

# SHA-256 of https://www.apache.org/licenses/LICENSE-2.0.txt
canonical_sha256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

if [ ! -e "$license_file" ]; then
  echo "FAIL: $license_file not found" >&2
  exit 1
fi

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Restore the appendix placeholder so the file can be compared with the published text.
actual_sha256="$(sed -E 's/^   Copyright [0-9]{4}(-[0-9]{4})? .+$/   Copyright [yyyy] [name of copyright owner]/' "$license_file" | sha256_of_stdin)"

if [ "$actual_sha256" = "$canonical_sha256" ]; then
  echo "ok: $license_file matches the Apache License 2.0 text apart from the copyright line"
  exit 0
fi

echo "FAIL: $license_file differs from the Apache License 2.0 text published at https://www.apache.org/licenses/LICENSE-2.0.txt" >&2
echo "  sha256 with the copyright placeholder restored: $actual_sha256" >&2
echo "  sha256 of the published text:                   $canonical_sha256" >&2

# Wording from the drift this check was written for, shown as a hint when present.
drift_lines="$(grep -n \
  -e 'submitted to the Licensor' \
  -e 'received by the Licensor' \
  -e 'excluding any notices' \
  -e 'OpenPGP' \
  "$license_file" || true)"
if [ -n "$drift_lines" ]; then
  echo "  lines with wording that is not in the published text:" >&2
  printf '%s\n' "$drift_lines" | sed 's/^/    /' >&2
fi
echo "  compare with: diff <(curl -sL https://www.apache.org/licenses/LICENSE-2.0.txt) \"$license_file\"" >&2
exit 1
