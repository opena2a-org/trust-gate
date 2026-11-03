# OpenA2A Trust Gate

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

> **[OpenA2A](https://github.com/opena2a-org)**: [CLI](https://github.com/opena2a-org/opena2a) · [HackMyAgent](https://github.com/opena2a-org/hackmyagent) · [Secretless](https://github.com/opena2a-org/secretless-ai) · [AIM](https://github.com/opena2a-org/agent-identity-management) · [Browser Guard](https://github.com/opena2a-org/ai-browserguard) · [DVAA](https://github.com/opena2a-org/damn-vulnerable-ai-agent)

[Website](https://opena2a.org) · [Discord](https://discord.gg/uRZa3KXgEn)

This action is retired. Its one step fails every run and prints a pointer to the replacement: the `audit` command of [ai-trust](https://github.com/opena2a-org/ai-trust), which checks the AI package dependencies a project declares against the OpenA2A Registry.

## Replace the trust-gate step

Add ai-trust to the repository as a development dependency, so the lockfile pins its version:

```bash
npm install --save-dev ai-trust
```

Remove the trust-gate step and run `audit` in a job that needs only read access to the repository:

```yaml
name: AI package trust

on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  ai-trust:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npx ai-trust audit package.json --min-trust 3
```

`audit` reads the `dependencies` and `devDependencies` of `package.json`, or a requirements file, looks each package up and lists general-purpose libraries as out of scope. It exits 2, failing the job, when a package has a warning or blocked verdict, falls below `--min-trust`, or is not in the registry and was not scanned. It exits 1 on an operational error, a registry that cannot be reached included. `--min-trust 3` requires a HackMyAgent scan; the default, 2, lets a listed but unscanned package pass. Options and exit codes: [ai-trust command reference](https://github.com/opena2a-org/ai-trust/blob/main/docs/commands.md#audit).

For a Python project, pass `requirements.txt` in place of `package.json`. A repository without `package.json` runs the same command as `npx -y ai-trust@X.Y.Z audit requirements.txt --min-trust 3`, with `X.Y.Z` the ai-trust release it pins. `audit` does not read `pyproject.toml`.

ai-trust sends usage telemetry by default, and each event carries an install ID that identifies the machine. `OPENA2A_TELEMETRY=off` turns it off for a run; [its README](https://github.com/opena2a-org/ai-trust#telemetry) says what is sent.

## Inputs and their counterparts

`min-trust-level` becomes `--min-trust`, `registry-url` becomes `--registry-url` with the URL, placed before `audit`, and `package-file` becomes the file argument. `fail-on-warning`, `check-aim` and the pull request comment have no counterpart: the job fails on exit 2 for a warning, a blocked verdict or a package below `--min-trust` alike, and `continue-on-error: true` on the step keeps the job going in every case.

## License

Apache-2.0

---

Part of the [OpenA2A](https://opena2a.org) ecosystem. See also: [Trust Badge Action](https://github.com/opena2a-org/trust-badge-action), [AIM](https://github.com/opena2a-org/agent-identity-management), [OpenA2A CLI](https://github.com/opena2a-org/opena2a).
