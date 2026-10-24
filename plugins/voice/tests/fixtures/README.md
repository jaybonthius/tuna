# Spoken command recordings

Short recordings of spoken commands for `make voice-command-check`, the manual check of spoken commands against the real speech worker (never run by `make test`). Each phrase is stored twice: `.f32` (raw float32 little-endian mono 16 kHz, what the worker reads) and `.wav` (16-bit mono 16 kHz, for listening and for a browser's fake microphone).

Command names: `split-view-right`, `other-view`, `undo`, `next-line`, `kill-region`, `beginning-of-buffer`, `execute-extended-command`, `tab-new`, `delete-view`, `set-mark-command`.

Near misses and other speech: `split-view` (a name cut short), `next-lime`, `undo-that`, `delete-the-view`, `kill-the-region`, `what-time-is-it`.

## Provenance

Generated once, on 2026-10-24, with the Piper text-to-speech program (`piper-tts` 1.8.0 from PyPI, in a throwaway virtual environment outside this repository) and its `en_US-lessac-medium` voice (Lessac dataset), one phrase per file, then converted from Piper's 22,050 Hz output with ffmpeg:

```sh
echo "split view right" | piper -m en_US-lessac-medium.onnx -f split-view-right.raw.wav
ffmpeg -i split-view-right.raw.wav -ar 16000 -ac 1 -f f32le split-view-right.f32
ffmpeg -i split-view-right.raw.wav -ar 16000 -ac 1 -c:a pcm_s16le split-view-right.wav
```

Piper is not a dependency of Tuna or of any build or test; these files are all that is kept.
