# OpenA2A Trust Gate

A composite GitHub Action that checks AI package dependencies against the [OpenA2A Registry](https://registry.opena2a.org) trust API and verifies AI agent identity status in pull requests. If any dependency falls below the configured trust threshold, the CI step fails, preventing untrusted packages from entering your supply chain.

## Features

- **Dependency trust verification** -- scans `package.json`, `requirements.txt`, and `pyproject.toml` against the OpenA2A Registry trust API
- **AIM identity check** -- detects whether the repository has Agent Identity Management (AIM) initialized, including identities, policies, signatures, and governance
- **AI tool artifact detection** -- identifies files and commit metadata that indicate AI-assisted changes
- **PR comments** -- posts a formatted summary of trust and identity status directly on pull requests

## Quick Start

```yaml
- uses: opena2a-org/trust-gate@v2
  with:
    min-trust-level: 3
    check-aim: true
    post-comment: true
```

The action auto-detects dependency files (`package.json`, `requirements.txt`, `pyproject.toml`) and queries the OpenA2A Registry for trust data on each dependency. It also checks for AIM initialization and AI tool artifacts in the PR.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `min-trust-level` | Minimum trust level required (0-4) | `3` |
| `fail-on-warning` | Fail the step when packages are below the threshold but not blocked | `true` |
| `registry-url` | OpenA2A Registry API URL | `https://api.oa2a.org` |
| `package-file` | Path to a specific dependency file. If omitted, the action auto-detects supported files in the repository root. | (auto-detect) |
| `check-aim` | Whether to check AIM agent identity status | `true` |
| `post-comment` | Post results as a PR comment (requires `GITHUB_TOKEN`) | `true` |

## Outputs

### Dependency Trust

| Output | Description |
|--------|-------------|
| `result` | JSON summary of all findings (safe, warning, blocked, unknown counts and per-package details) |
| `safe-count` | Number of packages at or above the minimum trust level |
| `warning-count` | Number of packages below the threshold but not blocked |
| `blocked-count` | Number of packages with trust level 0 (blocked) |

### AIM Identity

| Output | Description |
|--------|-------------|
| `aim-initialized` | Whether `.opena2a/` directory exists in the repository |
| `identity-count` | Number of registered agent identities (Ed25519 keypairs) |
| `has-policy` | Whether `policy.json` capability policy exists |
| `signature-count` | Number of config tamper-detection signatures |
| `has-governance` | Whether `SOUL.md` governance file exists |

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

## AIM Identity Check

When `check-aim` is enabled (the default), the action verifies:

| Check | What It Looks For |
|-------|-------------------|
| AIM Initialized | `.opena2a/` directory in the repository root |
| Agent Identities | Ed25519 keypair JSON files in `.opena2a/identities/` |
| Capability Policy | `.opena2a/policy.json` restricting agent access |
| Config Signatures | Tamper-detection signatures in `.opena2a/signatures/` |
| Governance | `SOUL.md` behavioral safety document |

The check also detects AI tool artifacts in the PR diff:
- Files in `.claude/`, `.cursor/`, `.copilot/`, `.aider`, `.mcp/`
- Changes to `CLAUDE.md`, `.cursorrules`, `SOUL.md`, `HEARTBEAT.md`
- MCP configuration files (`mcp.json`, `.mcp.json`)
- Commit author/committer metadata matching AI tool patterns

## PR Comment

When `post-comment` is enabled and the action runs on a `pull_request` event, it posts a comment on the PR with:
- Trust gate status (PASS / WARNING / FAIL)
- Dependency trust summary table
- AIM identity status table
- AI tool activity details (if detected)
- Recommendation to initialize AIM if not present

The comment is updated on subsequent pushes rather than creating duplicates.

## Example Workflow

```yaml
name: Trust Gate
on:
  pull_request:
    branches: [main]

permissions:
  pull-requests: write
  contents: read

jobs:
  trust-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run Trust Gate
        id: trust-gate
        uses: opena2a-org/trust-gate@v2
        with:
          min-trust-level: 3
          check-aim: true
          post-comment: true

      - name: Print results
        if: always()
        run: |
          echo "Safe: ${{ steps.trust-gate.outputs.safe-count }}"
          echo "Warning: ${{ steps.trust-gate.outputs.warning-count }}"
          echo "Blocked: ${{ steps.trust-gate.outputs.blocked-count }}"
          echo "AIM: ${{ steps.trust-gate.outputs.aim-initialized }}"
          echo "Governance: ${{ steps.trust-gate.outputs.has-governance }}"
```

See [`examples/trust-gate.yml`](examples/trust-gate.yml) for a full example.

### Using the JSON Output

The `result` output contains a full JSON summary that can be used in subsequent steps:

```yaml
- name: Process trust results
  if: always()
  run: |
    echo '${{ steps.trust-gate.outputs.result }}' | jq '.packages[] | select(.verdict == "warning")'
```

### Specifying a Dependency File

If your dependency file is not in the repository root, or you want to check a specific file:

```yaml
- uses: opena2a-org/trust-gate@v2
  with:
    package-file: services/api/package.json
```

### AIM-Only Check (Skip Dependency Scan)

To run only the AIM identity check without dependency trust scanning:

```yaml
- uses: opena2a-org/trust-gate@v2
  with:
    check-aim: true
    post-comment: true
```

If no dependency files are found, the trust check is skipped and only AIM results are reported.

## Supported Dependency Files

| File | Ecosystem | Parsing |
|------|-----------|---------|
| `package.json` | npm / Node.js | Reads `dependencies` and `devDependencies` via `jq` |
| `requirements.txt` | Python / pip | Strips version specifiers, comments, extras, and option lines |
| `pyproject.toml` | Python / PEP 621 | Parses the `[project] dependencies` array |

When no `package-file` is specified, the action checks for all three files and processes every one it finds.

## Requirements

The action runs as a composite step using `bash`, `curl`, and `jq`. All three are pre-installed on GitHub-hosted runners (`ubuntu-latest`, `macos-latest`, `windows-latest` with Git Bash).

The `post-comment` feature requires `gh` CLI (pre-installed on GitHub-hosted runners) and the `pull-requests: write` permission.

## How It Works

1. Detects or reads the specified dependency file(s)
2. Extracts dependency names from each file
3. Sends a batch request to `POST /api/v1/trust/batch` on the OpenA2A Registry
4. Categorizes each dependency by trust level relative to the configured threshold
5. Prints a summary table with per-package verdicts
6. Checks AIM identity status (initialization, identities, policies, signatures, governance)
7. Detects AI tool artifacts in the PR diff and commit metadata
8. Posts a formatted comment on the PR with trust and identity results
9. Sets GitHub Actions outputs with counts and full JSON results
10. Exits with code 1 if any blocked packages are found, or if warning packages are found and `fail-on-warning` is enabled

## Standalone AIM Check

The `scripts/aim-check.sh` script can be used independently outside of the composite action:

```bash
GITHUB_WORKSPACE=/path/to/repo bash scripts/aim-check.sh
```

This is useful for local development or integration into other CI systems.

## Links

- [OpenA2A Registry](https://registry.opena2a.org) -- the trust authority for AI packages
- [OpenA2A Registry API documentation](https://api.oa2a.org/api/v1)
- [Trust API: batch endpoint](https://api.oa2a.org/api/v1/trust/batch)
- [AIM (Agent Identity Management)](https://github.com/opena2a-org/agent-identity-management)
- [OpenA2A CLI](https://github.com/opena2a-org/opena2a)

## License

Apache-2.0
