# Brief: voice dictation

**Date:** 2026-10-23. **Status:** proposed, awaiting the owner's approval. Uses the owner's local, unpublished [`gerbil-parakeet`](../../../gerbil-parakeet/) binding and the `grammar-constraints` branch of `~/Code/parakeet.cpp`. Spoken commands with a grammar come later and reuse all of this.

## What we're building and why

Talk, and the words appear in the buffer as you speak, at the cursor, a few words at a time. `C-c v` starts dictation and `C-c v` or `C-g` stops it.

Parakeet's streaming models only ever add text: each piece of audio either finalizes a few more words or nothing. Nothing already written is revised, so the buffer just grows; there is no provisional text to replace. (Only the grammar stream, for commands later, has a provisional part.)

Three facts shape the design:
- **Parakeet must run in its own process.** Its calls block the whole Gerbil runtime, including Tuna's web server, editor and `C-g` (the binding's documentation says so). So a small worker program, built against `gerbil-parakeet`, does the recognizing; Tuna talks to it over a pipe. This is Tuna's first subprocess.
- **The microphone is the browser's.** Your computer running Tuna may not be where you are. The tab captures audio, as it captures keys, and sends it to the server. Browsers give pages a microphone only on HTTPS or `localhost`, which both of your setups are.
- **Audio does not go through the editor thread.** It goes from the page straight to the worker's pipe; only the recognized words become an editor task.
- **The web plugin knows nothing about microphones** (owner, 2026-10-23). It offers general page machinery any plugin can use, the way it already serves any plugin's stylesheets: add a script to the page, receive a tab's posts at a plugin's own address, and send one tab a one-time instruction. The microphone plugin owns its page script, its address and everything about audio, and only declares that it needs the page service.

## The picture

**Status:** planned.

![How speech becomes text](../diagrams/voice-dictation.svg)

## A walkthrough

1. **Start.** You are in `notes.txt` and press `C-c v`. `voice-dictate` remembers where the cursor is (a marker), starts the worker if it isn't running, and asks this tab to start its microphone. The first time, the browser asks your permission. The echo area says "Listening… (C-c v to stop)".
2. **Talk.** The tab sends a chunk of audio every tenth of a second. The worker decodes as it goes, and every time it finalizes words ("Well, I don't"), the voice plugin inserts them at the marker. You see them a fraction of a second after you say them.
3. **Type meanwhile.** You fix a typo above the marker. The marker moves with your edit, as point does, so later words still land where dictation is going.
4. **Stop.** `C-c v` again: the tab stops the microphone, the worker flushes the last words, and dictation ends. Undo removes what was dictated, one sentence at a time.

## A code sample (package author's view)

Another package can listen to dictation instead of inserting it, for example to search for what you say:

```scheme
(voice-start! (lambda ((words : :string)) (search-forward words)))
(voice-stop!)
```

The voice contract is that small: start with a function that receives each piece of new text, stop. Names are illustrative.

## How it gets built

Each stage runs in the browser. Nothing goes into the kernel.

1. **The worker.** A Gerbil program in `plugins/voice/worker/`, built with `gerbil-parakeet`'s `parakeet-compile` by a separate `make voice-worker`, so `make` and `make test` never need parakeet. It loads the model once, reads raw 16 kHz audio from its input, and writes each new piece of text as a line. It sets `OMP_WAIT_POLICY=PASSIVE`, without which this machine's build spun forever in a test.
2. **Page machinery in the web plugin**, in a new page contract: `add-script` (a plugin's own page script, served and loaded like its stylesheets), a plugin address that receives a tab's posts off the editor thread, and a one-time instruction to one tab after its next screen (what the clipboard copy does today, made general). Nothing about audio.
3. **The microphone plugin** (`plugins/microphone/`): its page script captures 16 kHz mono audio and posts it to its address; its contract is "start capturing on this tab, give me the audio; stop". It requires the page service.
4. **The voice plugin.** `voice-dictate`, the marker, starting and stopping the worker, and inserting text as it arrives. It requires the microphone contract; neither it nor the microphone plugin imports the web plugin.

Tests use a fake worker (a script that prints lines), so they run without models. The real worker is checked by hand with recorded speech.

**Not in this work:** spoken commands and grammars; showing a level meter or waveform; voice on Firefox if it lacks 16 kHz capture (to check); several people talking.

## Decisions for you

1. **Which model by default:** decided 2026-10-23, nemotron.
2. **Move the clipboard out of the web plugin too?** Today the web plugin listens to the kill ring to copy, the same mixing of concerns. With the page machinery, the clipboard becomes its own small plugin, which also gives the machinery its second user. **Recommendation: yes, in stage 2.**

Model comparison, for the record: `nemotron-3.5-asr-streaming-0.6b` (1 GB) writes capitals and punctuation, "Well, I don't wish to see it any more, observed Phoebe", and decoded 7.4 s of speech in 7.2 s including loading the model. `realtime_eou_120m` (176 MB) is about twice as fast but writes "well i don't wish to see it any more observed phoebe". **Recommendation: nemotron**, because dictated text without punctuation needs fixing by hand; the model is a plugin option either way.

## New terms

- **Dictation:** speech turned into text inserted in a buffer as you talk.
- **Speech worker:** the separate program that recognizes speech, so recognizing never freezes Tuna.
