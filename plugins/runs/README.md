# runs

Runs a program and shows its output in a buffer of its own as it arrives, between a header naming the command and a footer saying how the run ended. The buffer refuses edits and keeps no undo; `g` runs the command again, `C-c C-k` stops it, and killing the buffer stops it. Output is decoded as UTF-8, styled by `ansi-colors` and written with comint's carriage motion, so a progress meter stays one line.
