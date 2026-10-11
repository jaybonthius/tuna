# Tuna application state and checkpoint research

Status: research and recommendations, not implementation authorization. Investigated 2026-10-03 against current Tuna `a49f0ef112d3cb4831ecc16b96b466bb711d4dba`. The owner authorized a separate state plan and copying earlier research into this directory. The owner subsequently chose coherent checkpoints including unsaved buffer content, memory-only per-buffer undo initially, and automatic restoration of valid checkpoints. No new application “session” entity is implied.

## 1. Result

Recommend an application-owned composition of typed state models with one serialized owner, one shared in-memory update mechanism, revisioned read-only projections and a separate checkpoint representation. The buffer model remains authoritative for its content and history. Future layout/view models reference buffer identities rather than copying text; adding them should extend registered model definitions and their versioned codecs, not replace the state pipeline or require serializing native objects.

This differs deliberately from both Emacs's distributed mutable runtime and the older Racket immutable-root experiment. Mutable text storage does not contradict `UI = render(committed state)`. The required properties are explicit ownership, coherent updates and read-only rendering—not immutability of every live object.

## 2. Evidence boundaries and corrections

- **Current Tuna, observed:** `tuna/input.ss:33–42` dequeues and invokes keyboard commands serially; `tuna/server.ss:13–47` renders a static body; `tuna/main.ss:35–73` creates channels/worker/server and currently terminates the worker during cleanup. There is no implemented editor-state/checkpoint subsystem. The buffer document is a proposal. Earlier Gerbil reports refer to a different checkout/commit and their bounded runtime/completion APIs are not current interfaces.
- **Installed Gerbil, observed:** `/opt/gerbil/bin/gerbil version` returned `Gerbil v0.19-dev-62-g2591dcd9 on Gambit v4.9.8-18-gdcd677cd`. The reference source `/home/jay/Code/workbench-gerbil/gerbil` is `2591dcd9b7c6d2c4e9dd8611a17c5b1a5d82bbdb`. Installed/reference `std/os/file.ss` and `std/sync/channel.ss` were byte-identical. Older v19-dev-31 runtime probes are historical evidence, not fresh validation of every current primitive.
- **Emacs source, observed:** current `/home/jay/Code/emacs` is `541f693ca2e8de166cfe52c39bbfc497142215e9`; `emacs-30.2^{commit}` is `636f166cfc86aa90d63f592fd99f3fdd9ef95ebd`. The new raw Emacs report accidentally calls annotated tag object `29f3f150...` the release revision. Use the dereferenced commit above. Its `master` links are moving references; immutable references below pin the source actually checked.
- **Historical Racket, observed:** `/home/jay/Code/tuna` HEAD is `9c8f2977f11fd338f4c6a5c072919188b12c52a9`. Its copied plan describes format version 1, while the inspected implementation defines version 2. The source, not that older plan, establishes the implemented format. Its immutable-state/lock architecture and names are not requirements of the Gerbil app.
- Raw child reports and copied prior documents are retained without rewriting their claims. This synthesis corrects the discrepancies above and distinguishes facts from proposals. A report's default/recommendation does not authorize a current architectural choice.

## 3. Emacs facts and transferable lessons

### State ownership

**Documented/observed:** Emacs does not have one universal application-state store. Buffers own text, local variables/modes, marks and undo data; windows own display state and have window-specific point. For the selected window, the buffer point acts as the current point; switching windows transfers the relevant point value. Frame/window configurations are another scope.

Sources: [Window Point](https://www.gnu.org/software/emacs/manual/html_node/elisp/Window-Point.html), [buffer representation](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/buffer.h), [window representation](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.h), local `doc/lispref/windows.texi:5890–5965`, and [copied ownership research](prior/emacs-host-neutral-state-model.md).

**Inference for Tuna:** decide which model owns each value instead of putting all fields in a flat dictionary. Today's buffer/shared-navigation ownership can remain intact while future views own additional navigation contexts that reference the same buffer. A browser connection is not automatically such a view. No independent browser state or new session object is needed.

### Commands, revisions and redisplay

**Documented/observed:** Emacs normally executes pre-command work, a command and post-command work in order. Timers/process callbacks can run at waiting-capable points and become reentrant. Serialization alone does not guarantee rollback. Buffer modification generations support invalidation/redisplay; they are not an authoritative replay log. Atomic change groups cover participating buffer edits, not every global variable, window change or external effect.

Sources: [Command Loop](https://www.gnu.org/software/emacs/manual/html_node/elisp/Command-Loop.html), [Timers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Timers.html), [Filter Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Filter-Functions.html), [Atomic Changes](https://www.gnu.org/software/emacs/manual/html_node/elisp/Atomic-Changes.html), and [pinned command loop](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/keyboard.c).

**Recommendation for Tuna:** commands, timer requests and I/O outcomes re-enter the existing owner lane. Preserve the buffer proposal's stronger all-or-nothing in-memory update contract and make future model changes participate in it. Do not claim filesystem/process effects roll back. Rendering reads one committed revision and does not perform state mutation, file reads or identifier allocation.

### Persistence is selective, not a runtime dump

**Documented/observed:** optional desktop saving records eligible buffers, filenames, modes, positions, selected local/global values and optional frame/window configuration. Mode handlers support particular non-file buffers. Desktop restoration evaluates generated Emacs Lisp forms; it is not a portable dump of live objects or complete unsaved content. Desktop autosaving is conditional/idle-triggered. Lock checks and disabling autosave during failed loading help prevent accidental overwrites.

Sources: [Saving Emacs Sessions](https://www.gnu.org/software/emacs/manual/html_node/emacs/Saving-Emacs-Sessions.html), [Desktop Save Mode](https://www.gnu.org/software/emacs/manual/html_node/elisp/Desktop-Save-Mode.html), [pinned desktop source](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/desktop.el), particularly `desktop.el:317–381,1020–1064,1088–1240,1295–1411,1442–1497`.

**Documented/observed:** buffer autosave protects unsaved contents separately. `recover-session` uses an index of visited/autosave file pairs. `savehist` separately stores selected histories. Per-buffer undo lists are not normally saved by desktop/autosave.

Sources: [Auto-Saving](https://www.gnu.org/software/emacs/manual/html_node/elisp/Auto_002dSaving.html), [Undo](https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html), local `doc/lispref/text.texi:1371–1396`, [pinned savehist](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/savehist.el), and [pinned file recovery](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/files.el).

**Owner decision / deliberate difference:** Tuna will checkpoint current durable application data together with unsaved buffer content. This avoids reconciling cursor/layout metadata with independently captured or subsequently changed file content. Recovery never writes visited files. Undo remains per buffer and memory-only in the first implementation. A valid compatible checkpoint restores automatically; corrupt/incompatible state is preserved and blocks destructive replacement.

## 4. Earlier Tuna lessons

The [host-neutral Gerbil recommendation](prior/gerbil-tuna-host-neutral-state-architecture.md) separates authoritative application state, definitions and dynamic execution context; confines mutation to one owner; installs coherent revisions/projections before notifications; and uses coalesced latest-state wakeups. Retain those principles. Do not transplant its retired command/action APIs, live-binding machinery or refusal to define application fields into this concrete application plan.

The [Gerbil mechanisms report](prior/gerbil-host-neutral-state-mechanisms.md) and [functional comparison](prior/functional-application-state-patterns.md) warn about shallow-copy aliasing, callbacks under locks and confusing snapshots with event sourcing. A renderer's read-side representation and a recovery checkpoint can be different projections of the same state. Neither requires a persistent collection dependency or an event log.

The [Racket state plan](prior/racket-in-memory-editor-state.org) supplies useful format/lifecycle ideas: one tagged datum, schema validation before exposure, one writer, latest-pending coalescing, explicit retry/final-flush behavior. Its immutable state and previously implemented layouts are not a reason to build layouts now.

**Direct source fact:** [copied Racket persistence](prior/racket-persistence.rkt), `state->datum:71–92`, records buffers as ID/file pairs; `decode-views:144–150` constructs views with point zero. This particular checkpoint does not include text content or cursor position. That is a metadata-format limitation relative to the new owner's requirements, not proof that every historical Tuna variant failed recovery. Do not claim a full text/position round trip from metadata-only persistence tests. Its version-2 implementation differs from the copied version-1 plan.

## 5. Current Gerbil serialization and filesystem facts

**Documented:** Gambit's reader can evaluate `#.` forms when its readtable permits it. `readtable-eval-allowed?-set` makes a copy with that field changed. Sharing/serialization mode can admit graph notation and, in `serialize` mode, records, procedures and continuations. Merely calling `read` rather than `eval` is therefore not a sufficient data-only policy under an arbitrary inherited readtable.

Primary source at the current reference revision: `src/gambit/doc/gambit.txi:17358–17388,17517–17542`; implementations in `src/gambit/lib/_io.scm:10389–10411,13565...`; native Gerbil exports in `/opt/gerbil/src/gerbil/core/runtime.ss:976–987`.

**Recommendation:** construct a closed checkpoint-specific reader configuration; explicitly disable read-time evaluation and graph/record/procedure serialization; reject reader extensions, unknown types, multiple datums, invalid Unicode, duplicate records, illegal references and unsupported schema versions. Apply byte/object/depth limits and prove hostile-input behavior before relying on native reader configuration. Do not `load`, `include`, `eval`, import a package or reconstruct arbitrary classes from checkpoint data.

**Documented/observed:** Gambit `rename-file` may replace destinations, but its manual explicitly warns that not every filesystem supports atomic rename/existence testing. Gerbil `:std/os/file` exposes `file-device-sync`, backed by `fsync`; the installed/reference source is identical. This establishes available mechanisms, not a proven whole checkpoint durability sequence.

Primary sources: `src/gambit/doc/gambit.txi:13269–13280`; [current Gerbil OS file source](https://github.com/mighty-gerbils/gerbil/blob/2591dcd9b7c6d2c4e9dd8611a17c5b1a5d82bbdb/src/std/os/file.ss#L43-L46). Implementation must verify buffered-output flush, synchronization of the correct file and parent directory, atomic same-directory replacement, private permissions, cleanup and writer-lock lifetime on the actual local filesystem. Atomic process-crash replacement is not a universal power-loss guarantee.

## 6. Architectural recommendation

- One application root composes native typed state models. A small registration/codec protocol permits future layout/view/mode-state additions; no generic nested-path mutation, arbitrary-object serialization, mode framework or window implementation.
- One update coordinator owns preparation, shared reversal bookkeeping and root commit. The buffer retains its semantic edit/property/anchor/history logic but joins that coordinator when attached. A wrapper around an already committed buffer operation cannot provide cross-model rollback.
- One application publication revision identifies a coherent multi-model result. Buffer/source generations remain local invalidation tokens; they are not competing application commit clocks. Undo belongs to buffers; atomic updates do not imply global application undo.
- Query/render views and durable checkpoint data are distinct. Do not clone or serialize all text after every key merely to publish HTML. Capture durable data periodically on the owner; the writer sees only detached data.
- Schema-versioned model sections and stable typed resource references allow new models without changing the envelope or exposing storage internals. Treat missing critical schemas/unknown versions as recovery failures; preserve explicitly optional unknown payloads without executing them or silently dropping them.
- New models must demonstrate staged updates, rollback, export/decode, identity resolution, read isolation and source ownership. A two-model fixture can prove extension/composition now without implementing future layout.

## 7. Validation and residual risks

Research validation: checked current repository/toolchain/Emacs identities, read current input/server/main and native reader/filesystem contracts, checked installed/reference mechanism hashes, compared Racket plan and actual codec, and inspected both read-only reports. No state implementation, build, browser acceptance, power-loss simulation or user checkpoint files were run/read. Current native source-derived claims are narrower than the old reports' runtime-wide conclusions.

Implementation risks needing focused proof: common buffer/application transaction participation; continuation/cancellation-safe reversal; deeply detached snapshots; strict native reader configuration; stale writer completion ordering; safe shutdown without terminating a mutating owner; identity remapping; optional unknown payload retention; owner capture pauses for large text; and disk conflict handling. These are acceptance obligations, not reasons to silently broaden scope or add an actor/database framework.

## 8. Copied evidence and provenance

All earlier documents actually relied on by parent/children were copied under `prior/`; no old working tree was edited and no private live `.state` files were inspected. [SHA256SUMS](prior/SHA256SUMS) records the byte-for-byte source captures. Relative links inside verbatim historical copies retain their original meaning and may point to material not used/copied here.

| Copy | Original source |
|---|---|
| [Emacs state model](prior/emacs-host-neutral-state-model.md) | `/home/jay/Code/workbench-gerbil/research/emacs-host-neutral-state-model.md` |
| [Gerbil mechanisms](prior/gerbil-host-neutral-state-mechanisms.md) | `/home/jay/Code/workbench-gerbil/research/gerbil-host-neutral-state-mechanisms.md` |
| [Functional patterns](prior/functional-application-state-patterns.md) | `/home/jay/Code/workbench-gerbil/research/functional-application-state-patterns.md` |
| [Gerbil architecture](prior/gerbil-tuna-host-neutral-state-architecture.md) | `/home/jay/Code/workbench-gerbil/research/tuna-host-neutral-state-architecture.md` |
| [Older Gerbil current-state report](prior/gerbil-tuna-current-state-boundary.md) | `/home/jay/Code/workbench-gerbil/research/tuna-current-state-boundary.md` |
| [Racket state plan](prior/racket-in-memory-editor-state.org) | `/home/jay/Code/tuna/docs/plans/in-memory-editor-state.org` |
| [Racket Emacs reading map](prior/racket-emacs-research-map.md) | `/home/jay/Code/tuna/docs/reference/emacs-research.md` |
| [Prior research-corpus index](prior/racket-research-corpus-index.md) | `/home/jay/Code/workbench-racket/docs/tuna/research/README.md` |
| [Racket persistence source](prior/racket-persistence.rkt) | `/home/jay/Code/tuna/tuna/api/private/persistence.rkt` |

New research reports: [Emacs state/recovery](emacs-state-and-recovery.md), read-only child `393a3a79-b849-4ec5-8656-ad60a3863e41`; [prior Tuna comparison](prior-tuna-state-and-recovery.md), read-only child `b70d0e1b-6335-4c00-ae8d-9f13466ab3a3`. Their outputs were copied from workflow `dc3e90be-1d40-4199-8dfb-8406a33bc78f` into this repository so the evidence does not depend on retention-managed output paths.
