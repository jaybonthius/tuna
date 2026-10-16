# Advice scope follows the target

## Finding and decision

Named-function advice changes the shared package function, like source redefinition. Ownership determines which plugin/configuration contribution is removed; it does not make that shared function local to the editor instance that registered the contribution. Command and service targets instead follow the scope of their existing registries. No new runtime-membership query is needed for function advice in this milestone.

This corrects an extra isolation requirement the primary agent put in the stage-2a task. Neither the approved brief nor an actual product requirement asked for independently advised copies of the same loaded module definition inside one Gerbil process. Creating fresh kernels in tests does not instantiate fresh Gerbil modules. Tests must clean up owned advice and distinguish ordinary module-wide function changes from runtime-owned command/service state. The single production kernel is created in `tuna/kernel/state.ss`; other `new-kernel` calls are in test support and kernel-isolation tests.

## Emacs evidence

Source baseline: `/home/jay/Code/emacs` at `541f693ca2e8de166cfe52c39bbfc497142215e9`; executable probe: installed Emacs 30.2, not this source HEAD.

- The manual describes `advice-add` as modification of the named function and its existing callers, not the current buffer: [`doc/lispref/functions.texi:2140–2187,2210–2214`](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/functions.texi#L2140-L2214).
- The implementation installs the composition in `(symbol-function symbol)`: [`lisp/emacs-lisp/nadvice.el:509–537`](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/emacs-lisp/nadvice.el#L509-L537). Each symbol has a function cell ([`symbols.texi:39–82`](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/symbols.texi#L39-L82)). Buffers and frames do not get separate copies of that function cell.
- Local function-valued slots are explicitly different: `add-function` on `(local variable)` affects that buffer's variable, while ordinary variable places affect the global value ([`functions.texi:2012–2027`](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/functions.texi#L2012-L2027)).

A capped batch probe added around-advice while buffer A was current, then called the function in A and B: results `(20 20)`. After removing it, adding advice to a buffer-local function variable produced `(20 2)`. Both assertions passed. Probe: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage2/emacs-scope.el`; invocation: `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 45 emacs -Q --batch --load <probe>`. No frame-specific behavior was separately executed; shared function-cell scope is source evidence.

## Other prior art and Tuna's boundary

Racket distinguishes module declarations from module instances. Its [namespace guide](https://docs.racket-lang.org/guide/mk-namespace.html) explicitly describes attaching shared module instances versus instantiating unattached modules afresh. This supports following the actual binding/instance rather than inferring scope from whichever application object calls it. Gerbil's approved module-context lookup was already tested not to duplicate module state (spike 3). An editor-kernel object is not a second language image.

Tuna adds exact owner cleanup and inspection beyond Emacs; it need not add per-kernel dispatch guards to every advised shared function. Separate server processes naturally have separate module state. A future requirement for independently customizable language images in one process needs its own design, including ordinary source redefinition and module state, not an advice-only workaround.

## Implementation consequences

- Remove task-2a's parent-imposed cross-kernel function-advice filtering rule; keep all receipt/owner cleanup requirements.
- Keep named-function composition in the open function's cell. No scope map, guard chain, or new kernel API.
- Repeated registration/removal must track exact contributions and avoid leaking callbacks; disabling a plugin must not restore a stale base or erase another owner's advice.
- Command/service targets remain distinct because their existing target registries determine their scope. Do not extrapolate function-cell scope to runtime-local registries.
- Preserve current hook isolation: hooks announce runtime events and are not named-function advice targets. No hook change follows from this decision.
