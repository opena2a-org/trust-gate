# OpenA2A Trust Gate

[![Status: stable](https://img.shields.io/badge/status-stable-green)](STATUS.md)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

> **[OpenA2A](https://github.com/opena2a-org)**: [CLI](https://github.com/opena2a-org/opena2a) · [HackMyAgent](https://github.com/opena2a-org/hackmyagent) · [Secretless](https://github.com/opena2a-org/secretless-ai) · [AIM](https://github.com/opena2a-org/agent-identity-management) · [Browser Guard](https://github.com/opena2a-org/ai-browserguard) · [DVAA](https://github.com/opena2a-org/damn-vulnerable-ai-agent)

[Website](https://opena2a.org) · [Discord](https://discord.gg/uRZa3KXgEn)

A GitHub Action that checks AI package dependencies against the OpenA2A Registry and fails CI if any dependency falls below the configured trust threshold. With `check-aim`, it also reports which AIM files the repository holds and detects AI tool artifacts in pull requests.

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
| `check-aim` | Report AIM files and AI tool artifacts (see below) | `true` |
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
| `identity-count` | Number of `.json` files in `.opena2a/identities` |
| `has-policy` | Whether `policy.json` exists |
| `has-governance` | Whether `SOUL.md` exists |

## AIM Identity Check

When `check-aim` is enabled, the action reports whether `.opena2a/`, `.opena2a/policy.json` and `SOUL.md` (at the root or in `.opena2a/`) exist, and counts the `.json` files in `.opena2a/identities` and the files in `.opena2a/signatures`. It does not read keys or check signatures. It also detects AI tool files among the files the pull request changes (`.claude/`, `.cursor/`, `.copilot/`, MCP configs) and AI tool names in its commits' author and committer fields.

## Documentation

- [docs/dependency-files.md](docs/dependency-files.md): the dependency files the action reads, and how it auto-detects them.

## License

Apache-2.0

---

Part of the [OpenA2A](https://opena2a.org) ecosystem. See also: [Trust Badge Action](https://github.com/opena2a-org/trust-badge-action), [AIM](https://github.com/opena2a-org/agent-identity-management), [OpenA2A CLI](https://github.com/opena2a-org/opena2a).
