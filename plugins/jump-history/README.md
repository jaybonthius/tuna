# jump-history

The places jumps left, the one record of where the user was: `M-,` goes back and `C-M-,` forward again. Every switch to another buffer during a command records the place it left, and a plugin that jumps within a buffer records with `jump-history:push!`.
