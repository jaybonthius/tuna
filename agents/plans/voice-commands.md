# Plan: spoken commands

Brief (approved 2026-10-24): [`docs/briefs/2026-10-voice-commands.md`](../../docs/briefs/2026-10-voice-commands.md). Repositories: parakeet.cpp `/home/jay/Code/parakeet.cpp` (owner's working tree untouched; work in a new worktree `/home/jay/Code/parakeet.cpp__grammar-scores`, branch `grammar-scores` from v0.6.1 `5c9b0fb` with patches 0001–0004 as commits), `/home/jay/Code/workbench-gerbil/gerbil-parakeet` (commits allowed), Tuna. Owner: commits in both are fine; Piper only for one-time test audio, never a dependency.

## Invariants

- The native change is additive and upstreamable: no existing signature, struct or JSON field changes meaning; new JSON fields and one new `*_json` offline entry point; library conventions (no exceptions across the C boundary, malloc'd strings freed with `parakeet_capi_free_string`, docs in `docs/capi.md`, tests in `tests/test_capi_grammar.cpp`). It reports facts (scores, frames, alternatives), no confidence policy.
- Scores come from the existing search; `free_score` is the best unconstrained path over the same encoder frames in the same pass (encoder once).
- Tuna: confidence = clamp(exp((score − free_score) / frames), 0, 1) or an equivalent documented mapping to 0..1; the rule (run / offer list / no match) and all thresholds live in the voice plugin as settings; the list is `completing-read` with category `command`.
- Kernel unchanged; boundaries as in AGENTS.md; docs updated as each stage merges.

## Stages

1. **parakeet.cpp `0005-grammar-scores`.** Worktree and branch set up; patches as commits; the change; native tests with real models and existing fixtures (`speech.wav` against a grammar containing its real sentence vs unrelated phrases; `thunder.wav`); `git format-patch` output for stage 2.
2. **gerbil-parakeet.** Add `patches/0005-…` to `series.json` and the patch register; rebuild native; binding for the offline scored JSON (and docs for the new streaming fields); tests; reinstall `.install-check/local`.
3. **Tuna.** Worker grammar mode; `voice-command` (`C-c c` in the demo); grammar from the command registry (spoken names: hyphens to spaces, `voice-command-names` overrides), rebuilt when commands change; echo-area partials; listening ends by itself (owner 2026-10-24): when the partial can only be the prefix of one spoken name (`voice-command-finish-when-unique`), on the model's end of utterance or a pause after speech (`voice-command-end-pause`), or with no speech (`voice-command-start-timeout`), no key to stop; confidence rule with the knobs in the brief; `completing-read` list; one-time Piper clips of a few command names as test fixtures (Piper in a scratch venv, not a dependency) to set default thresholds; try a catch-all grammar branch and keep it only if it improves rejection.
