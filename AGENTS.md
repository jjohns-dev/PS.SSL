# AGENTS.md

## What this repo is

`PS.SSL`: a PowerShell 7 module wrapping `openssl` for CSRs, certificates, PFX bundles and remote TLS probing. Export list: `FunctionsToExport` in [PS.SSL.psd1](PS.SSL.psd1). User docs: [README.md](README.md); function template and style: [CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

| Path | Contents |
| ---- | -------- |
| `Public/` | One exported function per file |
| `Private/` | Internal helpers; not exported |
| `Tests/Common/` | Help, manifest, meta and path-literal tests run against every export |
| `Tests/<folder>/*.tests.ps1` | Collected on every OS; names are matched case-insensitively |
| `Tests/<folder>/*.tests.windows.ps1` | Collected only on Windows; never run on macOS/Linux |
| `Build/` | `build.ps1` shim for the shared [pwsh-module-ci harness](https://github.com/jjohns-dev/pwsh-module-ci/blob/main/docs/consumer-guide.md), plus `harness.psd1` settings |

## Build and test

```pwsh
./Build/build.ps1 -ResolveDependency -TaskList Init   # installs the harness's pinned build tools
./Build/build.ps1 -TaskList Analyze
./Build/build.ps1 -TaskList Test
./Build/build.ps1 -TaskList Cleanup                   # removes Staging/ and Artifacts/
```

All pass today: `Test` reports 346 passed, 0 failed, 14 NotRun on macOS.

`Build/build.ps1` is the harness shim: it runs the pwsh-module-ci version that `ci.yml` pins. The build tool pins (Pester, psake, PSScriptAnalyzer) live in pwsh-module-ci's `Build/depend.psd1`, not here; see the [consumer guide](https://github.com/jjohns-dev/pwsh-module-ci/blob/main/docs/consumer-guide.md).

## CI

All three workflows call `jjohns-dev/pwsh-module-ci@v2`. `ci.yml` runs `Init`, `CombineFunctionsAndStage`, `Analyze`, `Test`, then an independent "Verify Pester results" step. It does **not**:

- run macOS (`os-matrix` is ubuntu + windows);
- run `Network`-tagged tests (see below); run them locally from the repo root with `Invoke-Pester -Path ./Tests/Integration/PS.SSL.Network.Integration.tests.ps1 -TagFilter 'Network' -Output Detailed` (not `-Path ./Tests`: the other test files read the harness's environment variables at discovery and fail outside it);
- analyze `Tests/` or `Build/`: `Analyze` scans `Staging/` only. `pssa-sarif.yml` scans the whole repo. Both use the harness's PSScriptAnalyzer pin, 1.25.0.

`min-tests` is one floor for both legs, so it is derived from the lower leg's collected count; the derivation is in its `ci.yml` comment. Re-measure both legs from the JUnit artifacts when the suite shrinks deliberately.

`release.yml` publishes only on a `v*` tag push; merging publishes nothing. It also runs as a dry run on every PR: build, test and artifact, no publish.

## Conventions

- `main` ruleset: signed commits, linear history, PR plus required checks. Squash-merge only; head branches auto-delete.
- Branches are mostly `<type>/<slug>` (`fix/`, `ci/`, `chore/`).
- Recent subjects are conventional (`fix(Build):`, `ci:`, `docs:`, `chore(release):`); link the issue in the PR body.
- `Tests/Common/help.tests.ps1` is a template shared with sibling repos (jjohns-dev/pwsh-module-ci#17). Change it only under a tracking issue.

## Gotchas that have bitten here

- **The `Test` gate is on `$TestResults.Result -ne 'Passed'`, and now lives in the harness.** Discovery/container errors leave `FailedCount` at 0. Under Pester 6 an empty `-ForEach` without `-AllowNullOrEmptyForEach` is such an error; the old `FailedCount` gate dropped 166 tests and stayed green (#68). Mutation-checked: an empty-`-ForEach` probe fails the build with "0 failed test(s)".
- **openssl-dependent tests skip, not fail, when openssl is absent.** `Describe -Skip:` is evaluated at discovery; with openssl off `PATH` the integration file reports 4 skipped, Result `Passed`, and they still count toward `min-tests`.
- **`Network`-tagged tests are excluded from `Test`** by `PesterExcludeTag` in `Build/harness.psd1`, which the harness applies with `Filter.ExcludeTag`: live badssl.com probes flaked CI (#50). They are the 14 NotRun.
- **`CreateBuildArtifact` depends only on `Init`.** On a clean tree it fails with "Could not get manifest version"; stage first.
- **Build paths with `Join-Path`, never `"$HOME\Desktop"`.** The backslash is a literal filename character on Linux/macOS (#53). `Tests/Common/PathLiterals.tests.ps1` now fails such literals.
