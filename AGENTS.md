# AGENTS.md

## What this repo is

`PS.SSL`: a PowerShell 7 module wrapping `openssl` for CSRs, certificates, PFX bundles and remote TLS probing. Export list: `FunctionsToExport` in [PS.SSL.psd1](PS.SSL.psd1). User docs: [README.md](README.md); function template and style: [CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

| Path | Contents |
| ---- | -------- |
| `Public/` | One exported function per file |
| `Private/` | Internal helpers; not exported |
| `Tests/Common/` | Help, manifest, meta and path-literal tests run against every export |
| `Tests/*/*.Tests.windows.ps1` | Collected only on Windows; never run on macOS/Linux |
| `Build/` | `build.ps1` entry point, psake tasks, `depend.psd1` pins, analyzer settings |

## Build and test

```pwsh
./Build/build.ps1 -ResolveDependency -TaskList Init   # installs depend.psd1 pins
./Build/build.ps1 -TaskList Analyze
./Build/build.ps1 -TaskList Test
./Build/build.ps1 -TaskList Cleanup                   # removes Staging/ and Artifacts/
```

All pass today: `Test` reports 361 passed, 0 failed, 14 NotRun on macOS.

| Pin (`Build/depend.psd1`) | Version |
| ------------------------- | ------- |
| Pester | 6.2.0 |
| psake | 5.0.4 |
| PSScriptAnalyzer | 1.24.0 |

## CI

All three workflows call `jjohns-dev/pwsh-module-ci@v1`. `ci.yml` runs `Init`, `CombineFunctionsAndStage`, `Analyze`, `Test`, then an independent "Verify Pester results" step. It does **not**:

- run macOS (`os-matrix` is ubuntu + windows);
- run `Network`-tagged tests (see below);
- analyze `Tests/` or `Build/`: `Analyze` scans `Staging/` only. `pssa-sarif.yml` scans the whole repo, with PSScriptAnalyzer 1.25.0, not the 1.24.0 pin.

`min-tests: 337` is ~90% of the 375 collected (passed + NotRun) on 2026-10-27; re-measure when the suite shrinks deliberately.

`release.yml` runs only on a `v*` tag push; merging publishes nothing.

## Conventions

- `main` ruleset: signed commits, linear history, PR plus required checks. Squash-merge only; head branches auto-delete.
- Branches are mostly `<type>/<slug>` (`fix/`, `ci/`, `chore/`).
- Recent subjects are conventional (`fix(Build):`, `ci:`, `docs:`, `chore(release):`); link the issue in the PR body.
- `Tests/Common/Help.Tests.ps1` is a template shared with sibling repos (jjohns-dev/pwsh-module-ci#17). Change it only under a tracking issue.

## Gotchas that have bitten here

- **Keep the `Test` gate on `$TestResults.Result -ne 'Passed'`.** Discovery/container errors leave `FailedCount` at 0. Under Pester 6 an empty `-ForEach` without `-AllowNullOrEmptyForEach` is such an error; the old `FailedCount` gate dropped 166 tests and stayed green (#68). Mutation-checked: an empty-`-ForEach` probe fails the build with "0 failed test(s)".
- **openssl-dependent tests skip, not fail, when openssl is absent.** `Describe -Skip:` is evaluated at discovery; with openssl off `PATH` the integration file reports 4 skipped, Result `Passed`.
- **`Network`-tagged tests are excluded from `Test`** (`Filter.ExcludeTag`): live badssl.com probes flaked CI (#50). They are the 14 NotRun.
- **`CreateBuildArtifact` depends only on `Init`.** On a clean tree it fails with "Could not get manifest version"; stage first.
- **Build paths with `Join-Path`, never `"$HOME\Desktop"`.** The backslash is a literal filename character on Linux/macOS (#53). `Tests/Common/PathLiterals.Tests.ps1` now fails such literals.
