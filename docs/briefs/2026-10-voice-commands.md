# Brief: spoken commands

**Date:** 2026-10-24. **Status:** proposed, awaiting the owner's approval. Builds on [voice dictation](2026-10-voice-dictation.md). Touches three repositories: the owner's parakeet.cpp (a new local branch; his working tree is left alone), `gerbil-parakeet`, and Tuna.

## What we're building and why

Press `C-c c` and say a command's name, "split view right", and Tuna runs `split-view-right`. Any command works, including ones plugins add later.

Recognition is limited to a grammar made of every command's spoken name, so what you say can only come out as a real command. A grammar alone can't tell when you said something else: it forces any speech, or a cough, into the nearest command. So Tuna also needs a confidence, and acts on it:
- **High:** it runs the command and the echo area says which one.
- **Low:** it asks first: "Run `kill-buffer`? (y or n)".
- **No match:** "Didn't catch a command".

The threshold is a setting.

**Where the confidence comes from.** Parakeet's grammar search already scores every path it keeps, but doesn't report the score. The patch reports two numbers for each recognized command: the score of the command the grammar picked, and the score of the best transcription without the grammar, decoded from the same audio in the same pass (the expensive part, turning audio into features, runs once). If they are close, the grammar barely had to force anything: you said the command. If the free transcription scores far better, you said something else. Parakeet reports the numbers; the rule lives in Tuna.

## The picture

**Status:** planned.

![How a spoken command runs](../diagrams/voice-commands.svg)

## A walkthrough

1. **Say it.** In `notes.txt` you press `C-c c` and say "split view right". The echo area shows "split view…" as you speak.
2. **It ends by itself.** The command model hears that you stopped talking, about half a second later, so there is no key to finish.
3. **It runs.** The grammar picked "split view right", scoring close to the free transcription. Tuna runs `split-view-right`; the echo area says "split-view-right".
4. **A mumble.** You press `C-c c` and someone talks to you instead. The grammar forces that into "kill buffer", but the free transcription scores far better, so Tuna asks "Run `kill-buffer`? (y or n)", and you press `n`.

## A code sample (package author's view)

Nothing to do: a package's commands are speakable as soon as it is turned on. A package can give a command an easier name to say:

```scheme
(define-command ctx (magit-status) "Show the repository's status."
  spoken: "git status")
```

Names and keyword are illustrative.

## How it gets built

1. **The parakeet patch** (`0005-grammar-scores`, on a branch with patches 0001–0004 as commits), additive and upstreamable: each committed unit in the grammar stream's JSON gains `score` and `free_score`, plus the frames they cover; a new offline call returns the same as JSON in the library's existing `*_json` style. No existing function changes. Tests and docs in the library's own files.
2. **`gerbil-parakeet`:** the patch joins the series and the patch register; the native library is rebuilt; the binding exposes the offline scored result (streaming JSON simply gains fields); docs and tests.
3. **Tuna:** the speech worker gains a grammar mode; the voice plugin gains `voice-command` (`C-c c` in the demo), the grammar rebuilt whenever commands come or go, the provisional text in the echo area, and the confidence rule with its setting. The command model is `realtime_eou` (fast, and it detects when you stop talking); dictation stays on nemotron.

**Testing without recordings from you:** the existing recordings give a real match (a grammar containing what `speech.wav` actually says) and non-matches (the same speech, or thunder, against command names only). A few command clips are generated once with Piper, a text-to-speech program, and kept with the tests as audio files; Piper is not a dependency of anything. The starting threshold comes from these and is stated in the report.

**Also tried, kept only if it helps:** a catch-all branch in the grammar ("any other words"), which may reject non-commands on its own.

**Not in this work:** commands with spoken arguments ("go to line 40"), several commands in one breath, and a list of commands that always ask first (possible later as a setting).

## Decisions for you

None. You decided: commits in both repositories are fine; Piper only for one-time test audio; the confidence threshold is configurable.

## New terms

- **Grammar:** the list of phrases recognition is allowed to produce.
- **Confidence:** how little the grammar had to force the result, from comparing the two scores.
- **Free score:** the score of the best transcription with no grammar, over the same audio.
