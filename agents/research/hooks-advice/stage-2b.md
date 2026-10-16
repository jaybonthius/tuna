# Stage 2b implementation report

Implemented `M-x describe-advice` in the ordinary `advice-help` plugin. Commit: **`3a1f9cf03adb0c3153b6b2da138ca643579b50f3`** (`Add function advice inspection command`), branch `advice-help`, baseline `8acd176`.

## Behavior

- Completion lists advised functions only. Name plus source distinguishes same-spelled targets; typed values and name/source keys retain their identity.
- Help shows target name/source and installed layers explicitly outermost first, including each owner, name, kind, depth and source. An override produces a clear warning about suppressing inner advice and the original function.
- No advice produces useful help without prompting. After selection, the command re-queries `advised-functions`; removed advice is reported honestly and newly added layers appear.
- Deactivation removes the command without removing another owner's advice. Starter and demo configurations enable the plugin; no key binding was added.

## Changed files and boundaries

| Path | Owning layer / purpose | Imported concept contracts / services |
|---|---|---|
| `plugins/advice-help/plugin.ss` | Ordinary feature plugin; 51 lines | Commands, Completion, Help contracts only. Requires `commands-service`, `completion-service`, `help-service`; optional `completion-ui-service`, following the existing M-x convention and import-declaration checker. |
| `plugins/advice-help/gerbil.pkg` | Package registration | None |
| `plugins/advice-help/tests/integration/advice-help-test.ss` | Six behavior tests | Public Commands, Completion, Help contracts; existing Commands double, local Completion/Help doubles, fresh-kernel fixture. Only real plugin under test is `advice-help`. |
| `plugins/advice-help/tests/support/target-a.ss` | Open-function fixture | None |
| `plugins/advice-help/tests/support/target-b.ss` | Same-spelled open-function fixture in another module | None |
| `build.ss` | Workspace build registration | No concept contracts/services |
| `starter/init.ss` | Configuration: enable plugin | Existing Commands, Keys, Settings contract imports unchanged; add only advice-help implementation import/declaration |
| `demo/init.ss` | Configuration: enable plugin | Same narrow addition; existing contract imports unchanged |
| `tuna/tests/integration/boot-test.ss` | Starter-list expectation | Existing imports unchanged; no new contract/service |

**Kernel delta: zero.** Advice library, prelude, documentation, ADRs and STATUS unchanged. No shared contract, generic discovery framework, command/service advice or hungry-delete demo was added.

The task's claim that demo derives its starter list was incorrect at baseline: both configurations maintain explicit lists. Supervisor approved the narrow import/declaration addition to both, without introducing configuration sharing.

## Validation and history

Every build, test and Gerbil expansion used `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 2400` (4G for expansion/configuration probes). MCP balance checks bracketed Gerbil edits; capped contextual `import-module` expansion supplied syntax checks without launching an uncapped MCP subprocess.

Evidence directory: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage2b/`.

- `make deps`: passed (`deps.log`). Baseline and plugin builds passed (`baseline-build.log`, `plugin-build.log`).
- Focused `gerbil test ./plugins/advice-help/...`: passed, with final-line `OK` checked (`focused-tests.log`). Six cases cover no advice, selection/metadata/order/override, duplicate names, removal during prompting, addition during prompting and deactivation.
- First two test-file expansions failed on incorrect `prefix-in` syntax: argument order, then a keyword instead of an identifier prefix. Corrected to documented identifier prefixes; subsequent expansion passed (`test-expand.log`, `test-expand-2.log`, `test-expand-3.log`, final `test-expand-4.log`).
- Full `make test` attempt 1 failed at demo declaration validation: Completion's contract also requires declaring its optional UI service. Added the existing M-x-style optional declaration (`full-test.log`).
- Attempt 2 passed configuration validation but exposed the starter-list test's old expectation. Updated that one expectation (`full-test-2.log`).
- Attempt 3 passed all Gerbil suites, all 12 frontend tests and demo loading; final line `OK` (`full-test-3.log`). No HTTP timing flake occurred.
- Explicit starter and demo checks both passed (`config-checks.log`).
- `git diff --check` and staged diff checks passed before commit. After commit, `git status --porcelain=v1` and `git diff --cached --name-only` were empty. No owned Tuna server/process remains.

## Limits and next step

Browser validation is intentionally deferred to parent acceptance after command/service targets exist. This command currently describes **function advice only**; no command/service API is claimed. Independent reviewer acceptance remains required. Recommend review of `3a1f9cf`, then local merge if accepted.

## Parent acceptance

Merged as `e7deaad`. Parent reviewed the 51-line plugin, service declarations, six behavior tests and narrow configuration/build changes; independent capped `make test` passed without retry (`parent-make-test.log` in the scratch evidence directory). No kernel, prelude or advice-library changes. Browser acceptance remains scheduled after command/service targets are complete.
