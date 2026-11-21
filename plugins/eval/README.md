# eval

Evaluates Scheme from the running Tuna: `M-:` reads an expression and evaluates it in the REPL's environment, and `C-c C-r` and `C-c C-k` in Scheme buffers evaluate the region or the whole buffer, a module's file in its module. What the code writes and the values show in the echo area; with a prefix argument, `M-:` inserts the values at point instead.
