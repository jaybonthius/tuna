;; Programs find the compiled entry through TERMINFO_DIRS, which names a
;; tree of compiled entries, as tic writes it.
(unless (zero? (system "command -v tic > /dev/null"))
  (errorf 'build "tic, from ncurses, is needed to compile the terminfo entry"))
(unless (zero? (system "mkdir -p build/terminfo && out=$(tic -x -o build/terminfo src/terminal/xterm-ghostty.terminfo 2>&1) || { echo \"$out\" >&2; exit 1; }"))
  (errorf 'build "tic failed to compile xterm-ghostty.terminfo"))
