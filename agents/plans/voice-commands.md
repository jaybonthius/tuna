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

## Status

Stages 1 and 2 done 2026-10-24 (reports `/home/jay/Code/workbench-gerbil/scratch/voice-commands/stage{1,2}-report.md`). Stage 3 done 2026-10-24 on branch `voice-commands` (report `stage3-report.md` beside them).

## Stage 3 as built

- **Worker:** `tuna-voice-worker MODEL [LANGUAGE] --grammar FILE [--beam N]` (beam 8 from Tuna) writes the grammar stream's JSON document per read, the finalized one at end of input, `{"no_match":true}` when the stream ended without a match (after a feed it then drains its input), then `{"done":true}`.
- **Voice plugin** (`plugins/voice/plugin.ss`, pure parts in `plugins/voice/spoken.ss`): `voice-command`; the grammar is rebuilt per invocation from the visible commands (spoken name = name lowercased, hyphens as spaces, only words of a–z; `voice-command-names` overrides; commands sharing a spoken name are all offered), written to a private temporary file the worker reads once. Listening is the dictation machinery generalized: a listening hands each worker line, its end, or a failure to a handler.
- **Ending:** a committed unit decides at once; otherwise the pause (`voice-command-end-pause`, 0.5 s without a new partial after speech), a unique prefix (`voice-command-finish-when-unique`: a partial equal to the only name it begins finishes at once; an incomplete unique prefix waits `voice-command-unique-grace`, 0.4 s, then finishes; a finalize then without a unit offers that command in the list) stop the microphone and close the worker's input, and the decision comes from the finalized document; no partial within `voice-command-start-timeout` (5 s) stops everything: "No command heard". `C-g` cancels.
- **Decision:** confidence = min(1, exp((score − free_score) / frames)), alternatives with the unit's free score and frames. Run when the best ≥ `voice-command-run-confidence` and ≥ `voice-command-margin` ahead of the next and not in `voice-command-always-ask`; else the `completing-read` list (category `command`, confidence order, first selected) of up to `voice-command-candidates` at ≥ `voice-command-offer-confidence`; none: "Didn't catch a command".
- **Calibration** (`make voice-command-check`; Piper `en_US-lessac-medium` recordings in `plugins/voice/tests/fixtures/`, each run after 0.5 s of silence, then with 1.5 s of silence for the model's end of utterance ("eou") and with 0.5 s and then end of input ("pause"); 93 spoken names in the demo; confidence as above):

| Recording | Heard | eou | pause | With the defaults |
|---|---|---|---|---|
| beginning of buffer, execute extended command, next line, other view, tab new, undo | itself | 1.00 | 1.00 | run |
| split view right | itself | 0.99 | 0.99 | run |
| kill region | itself | 0.97 | 0.97 | run |
| delete view | itself | 0.96 | 0.96 | run |
| set mark command | itself | 0.44 | 0.91 | eou: list; pause: run |
| next lime (near miss) | next line | 1.00 | 1.00 | run (the model itself hears "line") |
| kill the region (near miss) | kill region | 0.66 | 0.47 | list |
| undo that (near miss) | undo | 0.61 | 0.68 | list |
| delete the view (near miss) | delete view | 0.60 | 0.59 | list |
| split view (cut short), what time is it, speech.f32, thunder.f32 | no match | – | – | Didn't catch a command |

  Further scratch recordings (not kept): end of buffer, previous line, scroll up command, yank, "tab knew" 1.00; "next lines" 0.92 (runs next-line); "beginning of the buffer" 0.30 / 0.76; "split few right" 0.47 / 0.35; hello there, new tab, other window, set the mark, split view left, undo it please: no match. Without leading silence the model misses first words ("set mark command" was heard as "command"), so the check adds 0.5 s. No unit carried alternatives with the plain grammar, so the margin is untested by these recordings.

  Chosen defaults: run 0.85 (lowest true command when finishing on a pause 0.91, highest near miss 0.76), offer 0.4 (keeps every near miss above 0.44 in the list), margin 0.1 (no evidence either way), candidates 5, end pause 0.5 s, unique grace 0.4 s, start timeout 5 s.
- **Catch-all branch: tried, not kept.** With 93 names, `other ::= word (" " word)*`, two- or three-word variants and `[a-z' ]+` all exceed parakeet's grammar limits (token arc limit or compilation work limit); only a single free word (`[a-z']+`) compiles. With it: non-commands were already all rejected and stay rejected (a catch-all word wins instead of no match); "kill the region" goes from a list to rejected; "set mark command" gets worse when finishing on a pause (0.91 run → 0.78 list) and better at end of utterance (0.44 → 0.79 list); everything else is unchanged. No clear gain, so no setting.
