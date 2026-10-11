# Removing the Emacs fork

## Decision and evidence

The requested outcome is the existing rich-HTML app on an unmodified Emacs, without a fork, source patch, executable-code patch or approximate fallback renderer. The public dynamic-module API does not expose completed glyph matrices. That API limitation does not prevent an exact-build private module: a stock executable with a full symbol table supplies the actual private function/data addresses, and its matching configured headers supply the layouts.

`native/emacs-web-stock.c` loads through the normal module API and verifies the complete `/proc/self/exe` SHA-256 before binding any private import. `native/stock-bindings.py` obtains addresses from the executable's full symbol table; `dl_iterate_phdr` supplies the main executable's PIE base. All pointers belong to this module. There is no executable-memory write, GOT/PLT rewriting, LD_PRELOAD, function interposition, `/proc/self/mem`, fabricated `emacs_value`, or type-based pointer guessing. Required symbols, ambiguous addresses and residual executable imports fail closed at build time. Executable mismatch fails closed at load time.

The private bridges are the actual upstream `lisp_to_value` and `value_to_lisp` functions. They allocate/check Emacs's environment value storage, including `--module-assertions`, rather than casting opaque public values or inventing roots. The former completed-display exporter remains synchronous: allocations alone do not run GC, no Lisp callback/redisplay is allowed during traversal, input is blocked, and Emacs's nonlocal-exit unwinding restores input blocking. The returned graph roots the real sources/fonts and owns copied compositions/image bytes. PNG caching remains owned by completed Cairo patterns, not by unmarked Lisp references. Changes to this traversal require rechecking that no GC safe point was introduced.

## UI entry paths

The stock public advice handles `x-popup-menu`, `x-popup-dialog`, `message-box`, `message-or-box`, explicit GTK file/font choosers and menu-bar activation. Nil-message clearing and nil-position menu precomputation are preserved. Stock `keyboard.c` calls `x_popup_menu_1` directly for menu-keymap input, bypassing Lisp `x-popup-menu` advice; `menu.c` still runs `x-pre-popup-menu-hook` before toolkit activation. The guard reads `menu-updating-frame`, so an explicitly targeted guarded frame is rejected even if another frame is selected.

Stock `message-or-box` calls `Fmessage_box` directly in C, so both public message entry points need guards. `yes-or-no-p` calls `Fx_popup_dialog` directly when dialog preferences and event origin permit it; `abort-minibuffers` also calls `Fyes_or_no_p` directly. Prompt wrappers dynamically bind dialog/file preferences on the attached frame, including the outer `abort-minibuffers` entry. Confirmations retain negative answers and quit behavior; they never invent an affirmative answer.

The core guard and stock hook are not instruction-for-instruction identical: the stock hook runs after keymap menu filters, and dynamically bound preferences can be inherited by callbacks that select another frame. Those limits are explicit in `native/README.md`. The app already serves one attached frame and rejects input when a different frame is selected. This work does not expand additional-frame routing, browser menus, clipboard/IME, busy-command interruption or other unfinished features.

## Compatibility and rejected alternatives

Support is deliberately exact-build: validated GNU 30.2/Linux x86-64/X11/GTK3/Cairo, original unstripped executable, its actual configured private headers, and normal modules. A different Emacs requires rebinding and restarting, not silent continuation. Stripped executables, debug sidecars, LTO/inlining that removes conversion functions, other architectures/backends/versions and enforced IBT/CFI are not validated/supported. The static private conversion functions are not necessarily indirect-branch landing sites; do not patch them or disable hardening to load the module. SHA equality proves executable identity, not that an arbitrary header tree belongs to it; the builder must supply the actual build tree, and the Makefile requires its `src/emacs` to match.

Reconstructing visible buffer text with Lisp coordinate probes would lose completed shaping, display-string source identity, image slices, resolved fonts/faces and readiness checks. Screenshots/terminal streaming would change the app's HTML/input contract. A custom patched stock build would simply recreate the original fork dependency. None was adopted.

## Primary source references

- [GNU Emacs dynamic-module values](https://www.gnu.org/software/emacs/manual/html_node/elisp/Module-Values.html): public opaque values and environment lifetime.
- [GNU 30.2 emacs-module.c](https://github.com/emacs-mirror/emacs/blob/emacs-30.2/src/emacs-module.c): real conversion/storage/marking and module-environment unwind cleanup.
- [GNU 30.2 keyboard.c](https://github.com/emacs-mirror/emacs/blob/emacs-30.2/src/keyboard.c), [menu.c](https://github.com/emacs-mirror/emacs/blob/emacs-30.2/src/menu.c): C menu-keymap dispatch, target frame and popup-hook placement.
- [GNU 30.2 editfns.c](https://github.com/emacs-mirror/emacs/blob/emacs-30.2/src/editfns.c), [fns.c](https://github.com/emacs-mirror/emacs/blob/emacs-30.2/src/fns.c), [minibuf.c](https://github.com/emacs-mirror/emacs/blob/emacs-30.2/src/minibuf.c): direct dialog/confirmation calls requiring outer entry guards.
- [Current validation](../../test/stock-emacs-results.md), including configured graphical fixtures and live browser evidence. Earlier fork-only rationale in historical plans/reports is superseded by this implementation, not rewritten as new evidence.
