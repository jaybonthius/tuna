# Brief: spoken commands

**Date:** 2026-10-24. **Status:** approved 2026-10-24 (owner), with candidate lists and the knobs below; built 2026-10-24 (all three stages; see [the overview](../overview.md#spoken-commands) for what was built, which is current where this brief differs: the default thresholds are run 0.85, margin 0.1, offer 0.4; a `voice-command-unique-grace` setting was added; easier spoken names come from the `voice-command-names` setting, not a `spoken:` keyword on `define-command`; the catch-all branch was tried and not kept). Builds on [voice dictation](2026-10-voice-dictation.md). Touches three repositories: the owner's parakeet.cpp (a new local branch; his working tree is left alone), `gerbil-parakeet`, and Tuna.

## What we're building and why

Press `C-c c` and say a command's name, "split view right", and Tuna runs `split-view-right`. Any command works, including ones plugins add later.

Recognition is limited to a grammar made of every command's spoken name, so what you say can only come out as a real command. A grammar alone can't tell when you said something else: it forces any speech, or a cough, into the nearest command. So Tuna also needs a confidence, and acts on it:
- **Clear:** one command is confident and well ahead of the next best: it runs, and the echo area says which one.
- **Unclear:** the best is less confident, or several commands score close together: Tuna shows them in the minibuffer as a completion list (the `M-x` list, with each command's key and description), best first and selected. `RET` runs the selected one, `C-n`/`C-p` move, typing narrows, `C-g` cancels: the ordinary Emacs way to choose (`completing-read`), as with `M-x`.
- **No match:** nothing confident enough: "Didn't catch a command".

**Where the confidence comes from.** Parakeet's grammar search already scores every path it keeps, but doesn't report the scores. The patch reports, for each recognized utterance, the few best commands the grammar accepted with their scores, and the score of the best transcription without the grammar, decoded from the same audio in the same pass (the expensive part, turning audio into features, runs once). If they are close, the grammar barely had to force anything: you said the command. If the free transcription scores far better, you said something else. Parakeet reports the numbers; the rule lives in Tuna.

## The picture

**Status:** built as drawn.

![How a spoken command runs](../diagrams/voice-commands.svg)

## A walkthrough

1. **Say it.** In `notes.txt` you press `C-c c` and say "split view right". The echo area shows "split view…" as you speak.
2. **It ends by itself.** You never press a key to finish (owner, 2026-10-24): listening ends as soon as what you've said can only be one command ("split view r…" has one possible ending), or when you pause after speaking, or after a few seconds if you say nothing. Pausing to end a command is how Talon, the main voice-coding tool, works.
3. **It runs.** The grammar picked "split view right", scoring close to the free transcription. Tuna runs `split-view-right`; the echo area says "split-view-right".
4. **Two close candidates.** You say "next line" a bit unclearly; "next line" and "end line" both score close. Tuna shows both, "next line" selected; `RET` runs it.
5. **A mumble.** Someone talks to you after `C-c c`. The grammar forces that into "kill buffer", but the free transcription scores far better, below the offer threshold: "Didn't catch a command". Nothing runs.

## A code sample (package author's view)

Nothing to do: a package's commands are speakable as soon as it is turned on. A package can give a command an easier name to say:

```scheme
(define-command ctx (magit-status) "Show the repository's status."
  spoken: "git status")
```

Names and keyword are illustrative.

## Knobs

Settings of the voice plugin, each with a default you can change in `init.ss` or with `set-setting` (names illustrative; confidence is a number from 0 to 1, where 1 means the grammar forced nothing):

| Setting | What it does | Default |
|---|---|---|
| `voice-command-run-confidence` | Run without asking when the best command is at least this confident | from testing, about 0.8 |
| `voice-command-margin` | ...and at least this much more confident than the runner-up | from testing |
| `voice-command-offer-confidence` | Offer only commands at least this confident; none left means "Didn't catch a command" | from testing |
| `voice-command-candidates` | At most this many commands in the list | 5 |
| `voice-command-always-ask` | Commands that always show the list, however confident (for example `kill-buffer`) | none |
| `voice-command-names` | Easier spoken names for commands, as pairs: `((magit-status . "git status"))` | none |
| `voice-command-finish-when-unique` | Finish as soon as what was said can only be one command, without waiting for the pause | on |
| `voice-command-end-pause` | Seconds of silence after speech that end listening (the model also reports the end of a phrase itself) | about 0.5 |
| `voice-command-start-timeout` | Seconds to wait for speech before giving up | 5 |
| `voice-command-model` | The model for commands | `realtime_eou` |

Setting `voice-command-run-confidence` above 1 means every command asks first.

## How it gets built

1. **The parakeet patch** (`0005-grammar-scores`, on a branch with patches 0001–0004 as commits), additive and upstreamable: each committed unit in the grammar stream's JSON gains its `score`, the `free_score` and the frames they cover, and `alternatives`, the next few distinct accepted texts with their scores (the search keeps several hypotheses; the patch reports them, it does not search more); a new offline call returns the same as JSON in the library's existing `*_json` style. No existing function changes. Tests and docs in the library's own files.
2. **`gerbil-parakeet`:** the patch joins the series and the patch register; the native library is rebuilt; the binding exposes the offline scored result (streaming JSON simply gains fields); docs and tests.
3. **Tuna:** the speech worker gains a grammar mode; the voice plugin gains `voice-command` (`C-c c` in the demo), the grammar rebuilt whenever commands come or go, the provisional text in the echo area, the confidence rule, the candidate list through `completing-read`, and the knobs above. The command model is `realtime_eou` (fast, and it detects when you stop talking); dictation stays on nemotron.

**Testing without recordings from you:** the existing recordings give a real match (a grammar containing what `speech.wav` actually says) and non-matches (the same speech, or thunder, against command names only). A few command clips are generated once with Piper, a text-to-speech program, and kept with the tests as audio files; Piper is not a dependency of anything. The starting threshold comes from these and is stated in the report.

**Also tried, kept only if it helps:** a catch-all branch in the grammar ("any other words"), which may reject non-commands on its own.

**Not in this work:** commands with spoken arguments ("go to line 40"), several commands in one breath, and a list of commands that always ask first (possible later as a setting).

## Decisions for you

None. You decided: commits in both repositories are fine; Piper only for one-time test audio, never a dependency; close candidates are offered as a list chosen with `RET`, cancelled with `C-g`; the thresholds are easy knobs.

## New terms

- **Grammar:** the list of phrases recognition is allowed to produce.
- **Confidence:** how little the grammar had to force the result, from comparing the two scores.
- **Free score:** the score of the best transcription with no grammar, over the same audio.
