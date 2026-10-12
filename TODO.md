# TODO

## Report or fix upstream (Gerbil / Gambit)

- [ ] **`gxc -O` hangs on an empty self-loop.** Compiling a module containing `(let lp () (lp))` with the optimizer never finishes; without `-O` it compiles. Found in stage 1 on Gerbil v0.19-dev-63 / Gambit v4.9.8; reproducible with a one-line module. Tuna works around it by giving such loops a body.
- [ ] **`thread-interrupt!` blocks its caller** until the target thread runs the interrupt, and raises `abandoned-mutex-exception` in the caller when the interrupt escapes. Check whether this is intended Gambit behavior and documented; if so, note it for Gerbil users, otherwise report it. Tuna interrupts from a helper thread.
