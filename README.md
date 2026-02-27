# OpenA2A Trust Gate

A composite GitHub Action that checks AI package dependencies against the [OpenA2A Registry](https://registry.opena2a.org) trust API. If any dependency falls below the configured trust threshold, the CI step fails, preventing untrusted packages from entering your supply chain.

## Quick Start

Add the following step to any GitHub Actions workflow:

```yaml
- uses: opena2a-org/trust-gate@v1
  with:
    min-trust-level: 3
```

The action auto-detects dependency files (`package.json`, `requirements.txt`, `pyproject.toml`) and queries the OpenA2A Registry for trust data on each dependency.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `min-trust-level` | Minimum trust level required (0-4) | `3` |
| `fail-on-warning` | Fail the step when packages are below the threshold but not blocked | `true` |
| `registry-url` | OpenA2A Registry API URL | `https://registry.opena2a.org` |
| `package-file` | Path to a specific dependency file. If omitted, the action auto-detects supported files in the repository root. | (auto-detect) |

## Outputs

| Output | Description |
|--------|-------------|
| `result` | JSON summary of all findings (safe, warning, blocked, unknown counts and per-package details) |
| `safe-count` | Number of packages at or above the minimum trust level |
| `warning-count` | Number of packages below the threshold but not blocked |
| `blocked-count` | Number of packages with trust level 0 (blocked) |

## Trust Levels

The OpenA2A Registry assigns trust levels on a 0-4 scale:

| Level | Name | Description |
|-------|------|-------------|
| 0 | Blocked | Known malicious or policy-violating package |
| 1 | Warning | Flagged for review, potential issues identified |
| 2 | Listed | Present in the registry with no scan data |
| 3 | Scanned | Automated security scans passed |
| 4 | Verified | Scanned and publisher identity verified |

Setting `min-trust-level: 3` (the default) requires all dependencies to have passed automated security scans at minimum.

## Example Workflow

```yaml
name: Trust Gate
on:
  pull_request:
    branches: [main]

jobs:
  trust-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check dependency trust
        id: trust
        uses: opena2a-org/trust-gate@v1
        with:
          min-trust-level: 3
          fail-on-warning: true

      - name: Print results
        if: always()
        run: |
          echo "Safe: ${{ steps.trust.outputs.safe-count }}"
          echo "Warning: ${{ steps.trust.outputs.warning-count }}"
          echo "Blocked: ${{ steps.trust.outputs.blocked-count }}"
```

### Using the JSON Output

The `result` output contains a full JSON summary that can be used in subsequent steps:

```yaml
- name: Process trust results
  if: always()
  run: |
    echo '${{ steps.trust.outputs.result }}' | jq '.packages[] | select(.verdict == "warning")'
```

### Specifying a Dependency File

If your dependency file is not in the repository root, or you want to check a specific file:

```yaml
- uses: opena2a-org/trust-gate@v1
  with:
    package-file: services/api/package.json
```

## Supported Dependency Files

| File | Ecosystem | Parsing |
|------|-----------|---------|
| `package.json` | npm / Node.js | Reads `dependencies` and `devDependencies` via `jq` |
| `requirements.txt` | Python / pip | Strips version specifiers, comments, extras, and option lines |
| `pyproject.toml` | Python / PEP 621 | Parses the `[project] dependencies` array |

When no `package-file` is specified, the action checks for all three files and processes every one it finds.

## Requirements

The action runs as a composite step using `bash`, `curl`, and `jq`. All three are pre-installed on GitHub-hosted runners (`ubuntu-latest`, `macos-latest`, `windows-latest` with Git Bash).

## How It Works

1. Detects or reads the specified dependency file(s)
2. Extracts dependency names from each file
3. Sends a batch request to `POST /api/v1/trust/batch` on the OpenA2A Registry
4. Categorizes each dependency by trust level relative to the configured threshold
5. Prints a summary table with per-package verdicts
6. Sets GitHub Actions outputs with counts and full JSON results
7. Exits with code 1 if any blocked packages are found, or if warning packages are found and `fail-on-warning` is enabled

## Links

- [OpenA2A Registry](https://registry.opena2a.org) -- the trust authority for AI packages
- [OpenA2A Registry API documentation](https://registry.opena2a.org/api/v1)
- [Trust API: batch endpoint](https://registry.opena2a.org/api/v1/trust/batch)

## License

Apache-2.0
