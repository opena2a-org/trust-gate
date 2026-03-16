# OpenA2A Trust Gate

A GitHub Action that checks AI package dependencies against the [OpenA2A Registry](https://registry.opena2a.org) and fails CI if any dependency falls below the configured trust threshold. Also verifies AI agent identity (AIM) status and detects AI tool artifacts in pull requests.

## Usage

Add to `.github/workflows/trust-gate.yml`:

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
      - uses: opena2a-org/trust-gate@v2
        with:
          min-trust-level: 3
          check-aim: true
          post-comment: true
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `min-trust-level` | Minimum trust level required (0-4, see below) | `3` |
| `fail-on-warning` | Fail when packages are below threshold | `true` |
| `registry-url` | OpenA2A Registry API URL | `https://api.oa2a.org` |
| `package-file` | Path to dependency file (auto-detects if omitted) | |
| `check-aim` | Check AIM agent identity status | `true` |
| `post-comment` | Post results as a PR comment | `true` |

## Trust Levels

| Level | Name | Description |
|-------|------|-------------|
| 0 | Blocked | Known malicious or policy-violating |
| 1 | Warning | Flagged for review |
| 2 | Listed | In registry, no scan data |
| 3 | Scanned | Automated security scans passed |
| 4 | Verified | Scanned and publisher identity verified |

## Outputs

| Output | Description |
|--------|-------------|
| `result` | JSON summary of all findings |
| `safe-count` | Packages at or above threshold |
| `warning-count` | Packages below threshold |
| `blocked-count` | Packages with trust level 0 |
| `aim-initialized` | Whether `.opena2a/` directory exists |
| `identity-count` | Number of registered agent identities |
| `has-policy` | Whether `policy.json` exists |
| `has-governance` | Whether `SOUL.md` exists |

## Supported Dependency Files

| File | Ecosystem |
|------|-----------|
| `package.json` | npm / Node.js |
| `requirements.txt` | Python / pip |
| `pyproject.toml` | Python / PEP 621 |

When no `package-file` is specified, the action auto-detects and processes all supported files found in the repository root.

## AIM Identity Check

When `check-aim` is enabled, the action verifies: `.opena2a/` initialization, Ed25519 agent identities, `policy.json` capability policy, config tamper-detection signatures, and `SOUL.md` governance. It also detects AI tool artifacts in the PR diff (`.claude/`, `.cursor/`, `.copilot/`, MCP configs, commit metadata).

## License

Apache-2.0

---

Part of the [OpenA2A](https://opena2a.org) ecosystem. See also: [Trust Badge Action](https://github.com/opena2a-org/trust-badge-action), [AIM](https://github.com/opena2a-org/agent-identity-management), [OpenA2A CLI](https://github.com/opena2a-org/opena2a).
