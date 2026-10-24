# Plan: voice dictation

Brief: [`docs/briefs/2026-10-voice-dictation.md`](../../docs/briefs/2026-10-voice-dictation.md) (model decided 2026-10-23: nemotron-3.5-asr-streaming-0.6b). Binding: `/home/jay/Code/workbench-gerbil/gerbil-parakeet` (local install at `.install-check/local`, models in `.deps/models`); patched parakeet.cpp at `/home/jay/Code/parakeet.cpp` branch `grammar-constraints`. Both local and unpublished; reference them by absolute path through a plugin option / make variable, never vendored.

## Invariants

- Parakeet never runs in Tuna's process (its calls block the whole Gambit VM). The worker is a separate executable; Tuna speaks to it over pipes.
- The browser only captures and sends audio, and starts or stops capture when the server says; it never names a command (ADR 7). Audio needs HTTPS or localhost.
- Audio bypasses the editor thread: web plugin → voice plugin → worker pipe, on their own threads. Only recognized text becomes an editor task (a job result / posted task), applied at a marker that moves with edits.
- Streaming text is append-only (`parakeet_capi_stream_feed` returns newly finalized text); no provisional replacement in this work.
- Placement (owner, 2026-10-23: the web plugin must not know about microphones): page contract (`plugins/web/contract.ss`, provided by the web plugin: `add-script`, a plugin-owned POST address receiving a client's bytes off the editor thread, a one-time per-client instruction after its next screen); microphone contract and plugin (`plugins/microphone/`: page script, its address, start capture on a client with a chunk callback, stop; requires the page service); voice contract and plugin (`plugins/voice/`: `voice-start!`, `voice-stop!`, `voice-dictate`); worker in `plugins/voice/worker/`. Subprocess handling stays private to the voice plugin until a second user needs a library. The kernel is unchanged.
- `make` and `make test` never need parakeet or models; plugin tests use a fake worker. `make voice-worker` builds the real one with `parakeet-compile`, `OMP_WAIT_POLICY=PASSIVE` set by the worker.
- Docs updated as each stage merges (overview, Emacs table, roadmap, brief/plan status).

## Stages

1. **Worker.** Reads float32 LE mono 16 kHz PCM from stdin, feeds `asr-stream-feed`, writes one JSON line per non-empty result (`{"text":…,"eou":…}`), finalizes on EOF; strips `<xx-YY>` language tags. Model path and language as arguments. Check: piping `speech.f32` in 100 ms chunks prints the expected text faster than real time with both models.
2. **Page machinery and microphone.** The page contract in the web plugin (generic; no audio), then the microphone plugin using it: AudioWorklet capture at 16 kHz mono (resampling in the page if the context won't run at 16 kHz), started and stopped by a one-time per-tab instruction like the clipboard copy; permission-denied and missing-API reports to the echo area. Check: a test page records chunks; Chrome and Firefox capture.
3. **Voice plugin.** `voice-dictate` toggle (`C-c v` in the demo; `C-g` stops), marker at point, worker lifecycle (started on first use, kept warm, stopped with the plugin), insertion of each line at the marker with one undo group per utterance (EOU) or per pause, echo-area status. Tests with a fake worker: text arrives at the marker; typing above moves the marker; stop flushes; turning the plugin off kills the worker. Browser check with real speech (or `speech.wav` played into the page's audio graph).
