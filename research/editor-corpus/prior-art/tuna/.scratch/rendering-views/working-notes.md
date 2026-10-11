# Rendering views: working research

Status: active research. These notes preserve evidence and design pressure before owner decisions. They are not a spec.

## Requested boundary

In scope:

- a layout leaf displays a view;
- a view refers to content and owns UI-specific state;
- the only current content is editable text;
- a text buffer owns its optional file association;
- raw browser rendering must remain driven by Racket-owned editor state.

Explicitly out of scope:

- markers, overlays, text properties, and other buffer metadata;
- file pickers, minibuffers, and other GUI surfaces;
- recreating Emacs one-for-one.

## Current Tuna model

At HEAD before this research:

- `editor-state` has global `subjects`, global `views`, and session-owned layout trees/frames (`tuna/api/private/state.rkt:42-49`).
- A `file-subject` is `(id file)` even when `file` is `#f`; its mutable text lives in a separate runtime-owned map (`tuna/api/private/state.rkt:50-51`, `docs/adr/0002-runtime-owned-subject-text.md`).
- A `view` is only `(id subject-id)` and is not attached to layout (`tuna/api/private/state.rkt:51`, `tuna/api/private/state.rkt:352-364`).
- A `layout-leaf` contains only its ID (`tuna/api/private/layout.rkt:28-34`).
- Sessions/trees create empty leaves without requiring any buffer or view (`tuna/api/private/state.rkt:329-392`).
- `split-layout-leaf` creates and focuses a new empty leaf (`tuna/api/private/state.rkt:747-818`).
- The session renderer emits empty leaf divs; it has no view/content resolver (`tuna/server/render.rkt:34-86`).
- Views and subjects persist, while editable text does not. Restoring a state file gives each subject empty text on first access (`docs/adr/0002-runtime-owned-subject-text.md`).
- Layout trees may be shared by multiple frames, including overlapping frame subtrees. Topology and layout-scroll anchors are shared; active leaf is frame-local (`docs/architecture.org:34-48`). A leaf-owned view binding would therefore be shared by every frame that sees that leaf.

Existing historical notes are not authoritative, but they reveal two prior assumptions worth reopening:

- `docs/plans/render-aggregate-plan.md` once treated layout leaves as view IDs before the recursive topology introduced distinct leaf IDs.
- `docs/architecture.org:59-65` says views are shareable across sessions, but neither the current API nor tests exercise attachment or sharing semantics.

## Vocabulary concern

`file-subject` is already a text buffer with an optional file, not necessarily a file subject. The public API consequently says `create-file-subject`, `get-subject-text`, and `get-subject-file` for the object the owner now calls a text buffer. This generic `subject` layer currently has one implementation and no demonstrated leverage.

Emacs places optional file identity on the buffer itself: `struct buffer` contains `filename_` and `file_truename_`, along with text and editing state (`../emacs/src/buffer.h:320-516`). The Elisp manual likewise defines the buffer file name as the file visited in that buffer, or nil (`../emacs/doc/lispref/buffers.texi:382-412`).

Provisional conclusion: rename the current subject/file-subject surface to text-buffer/buffer terminology now unless a concrete non-buffer content type justifies the abstraction. Future terminals, status pages, and completion lists can still be text buffers, as in Emacs.

## Emacs reference target

Research targets the local source checkout `/home/jay/Code/emacs` at commit:

`541f693ca2e8de166cfe52c39bbfc497142215e9`

Immutable source base:

`https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/`

Installed Emacs 30.2 is not the target.

## Emacs findings

### A live window combines a layout leaf and view state

Emacs arranges windows in a tree. Leaf windows display buffers; internal windows only arrange children. A leaf stores its buffer plus `start` and `pointm` markers (`../emacs/src/window.h:30-67`, `../emacs/src/window.h:100-176`).

This supports the same conceptual split Tuna wants, but Emacs stores both concerns in one `struct window`; Tuna does not need to copy that coupling.

### File identity belongs to the buffer

`struct buffer` owns the visited file name/truename and file fingerprint data, not the window (`../emacs/src/buffer.h:320-516`, `../emacs/src/buffer.h:648-676`). This supports the requested ownership boundary.

### Display position is per window

Each live window stores:

- displayed buffer (`contents`);
- display start (`start`);
- per-window point for nonselected windows (`pointm`);
- horizontal and vertical scroll values (`hscroll`, `vscroll`).

Evidence: `../emacs/src/window.h:136-176`, `../emacs/src/window.h:264-285`, `../emacs/src/window.h:452-474`.

The manual explicitly says each window has independent point when the same buffer is shown in multiple windows (`../emacs/doc/lispref/windows.texi:5890-5964`). `window-state-get` serializes buffer, selected status, hscroll, vscroll, point, and start as window state (`../emacs/lisp/window.el:6389-6485`).

### Emacs's selected-window point swap should not be copied

For the selected Emacs window, `window-point` comes from the buffer's point; nonselected windows use their own marker (`../emacs/src/window.c:1779-1800`). Selection saves old buffer point into the old window and loads the new window's point into the buffer (`../emacs/src/window.c:594-614`). The manual admits temporary selection can move buffer point unpredictably when several windows display one buffer (`../emacs/doc/lispref/windows.texi:5890-5939`).

Provisional Tuna lesson: keep point wholly view-owned. Selection should choose which view commands address, not swap a second buffer-owned point in and out.

### Changing a window's buffer resets view state

`set_window_buffer` updates the displayed buffer and, unless explicitly preserving same-buffer margins, resets hscroll/vscroll, initializes point from the buffer, initializes start from the buffer's remembered last start, invalidates derived end/cursor state, and requests redisplay (`../emacs/src/window.c:4335-4430`).

Provisional lesson: Tuna needs an explicit policy for replacing a leaf's view or changing a view's buffer. Silently retaining offsets from the old buffer is unsafe.

### Splitting creates independent window state

The low-level split allocates a new window object and then sets its buffer from the reference window (`../emacs/src/window.c:5378-5689`). The user-level split defaults to preserving the same point initially in both windows, but they remain distinct window objects (`../emacs/lisp/window.el:6005-6111`).

Provisional lesson: splitting a leaf should clone a view's initial state into a new view, not attach the same mutable/stateful view to both leaves by accident.

### Emacs preserves locations through layered history, not detached windows

The earlier leaf-owned-lifetime recommendation was too destructive. Exact Emacs behavior is more layered:

- A live window records every previously displayed live buffer as `(buffer, window-start, window-point)` and restores that exact pair when switching back in the same window (`../emacs/doc/lispref/windows.texi:4927-5024`, `../emacs/lisp/window.el:4590-4683`, `../emacs/lisp/window.el:4916-5061`).
- When a window stops displaying a still-live buffer, Emacs records the last display start and, subject to selected-window conditions, point on the buffer. A new window displaying that buffer is initialized from the buffer point and `last_window_start` (`../emacs/src/window.c:2500-2545`, `../emacs/src/window.c:4335-4384`, `../emacs/src/buffer.h:673-676`). Thus location can survive deletion of the particular window even though the window object and its private history do not.
- Killing a buffer normally removes that dead buffer from window histories; `kill-buffer-and-window` really kills the buffer and deletes the window (`../emacs/doc/lispref/windows.texi:4941-4960`, `../emacs/lisp/window.el:10667-10685`). Revisiting the file restores point only when an additional mechanism such as `save-place-mode` records file name to point on `kill-buffer-hook` and applies it on `find-file-hook` (`../emacs/lisp/saveplace.el:252-355`, `../emacs/lisp/saveplace.el:436-452`). A stock installed Emacs 30.2 `-Q` check killed a file buffer at point 12 and revisited it as a distinct buffer at point 1.

Tuna should not copy Emacs's duplicate buffer-point/window-point ownership. The relevant requirement is instead that removing a leaf must not automatically destroy reusable view state. A global view may be unattached and later rebound, preserving point on the view while the buffer remains live. Buffer killing/revisiting and any file-keyed saved-place policy belong to the later buffer-lifecycle feature.

Pinned references:

- Window history contract: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/windows.texi#L4927-L5024
- History recording/restoration: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/window.el#L4590-L4683 and https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/window.el#L4916-L5061
- Buffer fallback point/start: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.c#L2500-L2545 and https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.c#L4335-L4384
- Kill buffer and window: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/window.el#L10667-L10685
- Optional saved-place restoration: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/saveplace.el#L252-L355 and https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/saveplace.el#L436-L452

### Authoritative state and render caches are different

Emacs's window owns current/desired glyph matrices and last-rendered modification/cursor/end values (`../emacs/src/window.h:224-225`, `../emacs/src/window.h:280-389`). Redisplay separately derives a desired matrix from window+buffer state, compares it with the current matrix, then updates the physical display (`../emacs/src/xdisp.c:20-190`; `../emacs/src/dispextern.h:773-859`).

Provisional Tuna lesson: a view should hold authoritative logical UI state only. HTML/xexprs, measured rows, browser geometry, visible-end positions, and diff caches are derived renderer state and should not enter persisted view records now. Emacs's invalidation machinery is far beyond this feature and should not be copied without a measured need.

## Point behavior in other editors

“Point” is specifically Emacs vocabulary for the logical buffer position where editing commands act. Emacs also calls the per-window value “window point.” Other editors usually call the corresponding state a cursor or collapsed selection:

- Emacs gives each window an independent point. Its ordinary inactive `window-point` marker defaults to staying before text inserted exactly there, while the `insert` operation explicitly moves the selected/current point after the inserted text (`../emacs/doc/lispref/windows.texi:5890-5964`, `../emacs/doc/lispref/text.texi:397-445`).
- Neovim stores `w_cursor` on each window, and its public API explicitly states that different windows showing one buffer have independent cursor positions (`neovim/neovim` commit `ed5dcc0edf2ebea02c4c5d667a612cd6fb23cf81`, `src/nvim/buffer_defs.h:1129`, `src/nvim/api/window.c:68-90`).
- CodeMirror maps an editor selection through every transaction change. Its default mapping associates a collapsed cursor with the character before it, so generic insertion exactly there leaves it before the insertion; a transaction may instead supply an explicit resulting selection (`codemirror/state` commit `9c801279cb83011e6f92af778f4443406e8f1200`, `src/selection.ts:45-77,121-126`, `src/change.ts:106-139`, `src/transaction.ts:207-213`).
- Helix stores selections per `ViewId`, maps every view's selection through document changes, and maps a collapsed cursor with sticky after-association (`helix-editor/helix` commit `f6f3eb1fe4a73933466f30175843059a4381a985`, `helix-view/src/document.rs:144-145,1478-1497`, `helix-core/src/selection.rs:171-202`). Thus an insertion exactly at several views' cursors advances all of them.

There is broad agreement on maintaining positions through edits rather than merely clamping stale offsets. The insertion-boundary affinity is not universal. The current recommendation for Tuna is CodeMirror/Emacs-like separation: raw buffer edits left-map every view point; a future view-aware typing command explicitly advances only its source view. This preserves independent views when two points happen to coincide and requires no public marker abstraction.

Pinned references:

- Emacs window point: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/windows.texi#L5890-L5964
- Emacs insertion: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/text.texi#L397-L445
- Neovim independent window cursors: https://github.com/neovim/neovim/blob/ed5dcc0edf2ebea02c4c5d667a612cd6fb23cf81/src/nvim/api/window.c#L68-L90
- Neovim window cursor field: https://github.com/neovim/neovim/blob/ed5dcc0edf2ebea02c4c5d667a612cd6fb23cf81/src/nvim/buffer_defs.h#L1120-L1134
- CodeMirror selection mapping: https://github.com/codemirror/state/blob/9c801279cb83011e6f92af778f4443406e8f1200/src/selection.ts#L45-L77
- CodeMirror position affinity: https://github.com/codemirror/state/blob/9c801279cb83011e6f92af778f4443406e8f1200/src/change.ts#L106-L139
- CodeMirror transaction selection: https://github.com/codemirror/state/blob/9c801279cb83011e6f92af778f4443406e8f1200/src/transaction.ts#L207-L213
- Helix per-view selections and mapping: https://github.com/helix-editor/helix/blob/f6f3eb1fe4a73933466f30175843059a4381a985/helix-view/src/document.rs#L140-L149 and https://github.com/helix-editor/helix/blob/f6f3eb1fe4a73933466f30175843059a4381a985/helix-view/src/document.rs#L1478-L1497
- Helix collapsed-cursor mapping: https://github.com/helix-editor/helix/blob/f6f3eb1fe4a73933466f30175843059a4381a985/helix-core/src/selection.rs#L171-L202

## Design pressure discovered

### 1. View sharing semantics

If two leaves reference one view, they necessarily share point/start/scroll. That is materially different from two views of one buffer. Current documentation says views are shareable but gives no behavior.

Likely invariant: one displayed leaf references one independent view. Splitting clones the view; showing one buffer in two leaves means two views. A view may remain globally alive while unattached. Explicit synchronized views can be added only if a real feature needs them.

### 2. Leaf binding versus frame-local binding

Three materially different shapes exist:

1. `layout-leaf -> view-id`: direct and matches the requested phrase “leaf displays a view”; overlapping frames share the leaf's view.
2. `(frame-id, leaf-id) -> view-id`: preserves pure/shareable topology and permits overlapping frames to show different state, but a leaf no longer displays anything without frame context.
3. embed buffer/view state in the leaf: closest to Emacs but erases the requested seam and couples content state to layout edits.

The direct leaf reference is the current recommendation, provided the owner confirms that the same leaf seen through two frames is the same displayed view.

### 3. Empty leaves

Emacs live windows always display a buffer. Tuna currently creates empty leaves automatically. Making `view-id` optional preserves easy session creation but spreads an “empty display slot” case through validation, rendering, splitting, and commands.

Likely recommendation: every leaf always names a valid view. Session/tree/leaf creation must either receive a view or atomically create a default scratch buffer/view. This requires an explicit bootstrap policy.

### 4. View lifetime

A global view pool plus leaf references creates orphan and deletion questions:

- Can a view exist unattached?
- Can one view be attached twice?
- Does removing a leaf delete its view?
- Does replacing a leaf's view retain the old one for history?

There is currently no `delete-view` or `delete-subject` operation. A one-view-per-leaf invariant avoids synchronized state but requires ownership/lifetime rules rather than leaving global records to leak.

### 5. Positional state without markers

Emacs uses markers for both point and window start so edits adjust them. Markers are explicitly out of scope. Raw byte offsets can become out of range or point at different text after edits, especially edits made through another view.

This initially suggested three scope choices:

- attach views and render raw full text without positional fields;
- add numeric point/start with deliberately weak/clamped semantics;
- adjust the small fixed set of view positions during text edits without exposing general markers.

Grilling selected a fourth, narrower combination: point only, with one fixed left-biased edit transform for all view points. This tracks the sole authoritative view position without creating a public marker facility.

### 6. Persistence mismatch

View metadata is currently persisted; mutable buffer text is not. Persisting point/start now can restore offsets against an empty buffer. Any positional-state design must explicitly reset, clamp, defer, or change text restoration. Ignoring this creates invalid restored state.

### 7. Render read boundary

`session-main` is currently pure over a public session value, while text lives behind separate locked queries. Rendering a leaf will need session topology, view association, and immutable text. Per-leaf public queries are simple but do not form one coherent multi-buffer snapshot. A dedicated immutable render projection would be coherent but may be premature API surface.

Although per-leaf reads could make the first implementation shorter, grilling selected one private immutable render snapshot so mutable view association and text are never combined from different editor states.

### 8. Full-buffer HTML is intentionally naive

The existing gap buffer caches immutable byte snapshots, so the first full read after an edit is O(buffer size); conversion to a Racket string and SSE HTML still copy/encode the text. Sending the full session after every generic editor event is also O(total displayed text). Emacs's glyph matrices and modification counters optimize this, but Tuna's roadmap already reserves measured rendering work for TUNA-F-0018.

Recommendation: render full escaped text in a `<pre>` for the first behavior seam, make no cache/revision architecture now, and measure before optimizing.

### 9. Two meanings of scrolling

Tuna already calls Niri-style layout-strip movement `scroll` and stores layout scroll anchors in shared topology. Text viewport scrolling is separate per-view state. APIs/docs should consistently say “layout scroll anchor” versus “view start/text scroll” to avoid conflation.

## Pre-grilling candidate contract

Before owner decisions, the smallest internally coherent feature appeared to be:

- replace speculative subject/file-subject vocabulary with text-buffer terminology;
- make every layout leaf reference exactly one valid view;
- make every displayed view belong to at most one leaf;
- a view references one text buffer;
- a view owns one point that is adjusted through buffer edits;
- splitting creates a new view of the same buffer and point, independently mutable afterward;
- render the buffer's entire literal text in the leaf using `<pre>`;
- no cursor, selection, viewport scrolling, markers, overlays, mode line, file loading, or render cache;
- adjust roadmap wording so point/editing/scroll UI land in the capabilities that actually exercise them.

The grilling decisions below supersede this candidate where they differ.

## Grilling decisions

1. **View binding is leaf-owned, not frame-local.** A frame is only a pointer into the shared layout tree. When frames expose the same leaf, they expose the same view and future UI state. Model the association directly as `layout-leaf -> view-id`.
2. **A displayed view belongs to one leaf.** Distinct leaves may display the same buffer through distinct views, but may not reference the same view. Splitting should initialize a new independent view from the source view rather than synchronize future UI state.
3. **Every live leaf is bound.** A layout leaf always references a valid view; there is no unbound/empty display-slot state. Every leaf-creation path must therefore supply or atomically create a view.
4. **A new session gets a fresh unnamed buffer.** When no initial buffer is supplied, session creation atomically creates a fileless text buffer, a view of it, and the initial leaf. Sessions do not share a hidden editor-wide scratch buffer.
5. **Buffer is the canonical content identity.** Replace the speculative `subject` / `file-subject` vocabulary and APIs rather than retaining aliases or a generic internal layer. A buffer owns optional file association and live text logically, while the runtime may continue to hold mutable storage by buffer ID.
6. **The first concrete view state is point only.** A view owns one logical UTF-8 byte-boundary point. Viewport start, selection, measured rows, and other derived display state remain deferred.
7. **Generic edit mapping is left-biased.** Buffer edits map every affected view point through the replacement: points after the replaced range shift, points inside removed text collapse to its start, and a point exactly at a pure insertion remains before the inserted text. A future view-aware edit command explicitly advances only its source view. This is fixed point behavior, not a general marker abstraction.
8. **Point resets on restore.** Buffer text is not restored, so persisted/restored views start at byte offset 0 rather than retaining a position against absent content. Making text durable remains outside F-0007.
9. **Live point is an in-memory view field.** Point participates in immutable candidate-state updates, queries, and render projections. The persistence boundary deliberately restores it as zero; a separate mutable runtime point map would add rollback and lifecycle machinery without benefit.
10. **Views may outlive leaf attachment.** Removing a leaf detaches its view rather than deleting it. A view may be attached to zero or one leaf, so its point can be reused later while its buffer remains live. Buffer killing and file-keyed saved-place restoration are separate future lifecycle policy.
11. **Automatic view history is deferred.** F-0007 provides explicit atomic attachment/detachment only. Per-leaf previous-view history, global MRU selection, and “reopen this buffer” policy belong to F-0014 buffer switching.
12. **Ordinary leaf insertion attaches an explicit view.** `insert-layout-leaf` requires an existing unattached view ID and atomically validates and attaches it. It neither creates a buffer nor hides view creation inside a topology operation. Session bootstrap and splitting remain specialized creation paths.
13. **The first browser rendering shows complete literal buffer text.** Each leaf includes its leaf, view, and buffer identities and displays the buffer's full text with whitespace preserved and HTML metacharacters serialized as text. Cursor, selection, viewport clipping, and render optimization remain deferred.
14. **Rendering uses one private immutable snapshot.** A server-only query gathers the active session subtree, referenced view/buffer metadata, and immutable text snapshots under one editor lock. `session-main` renders that value without issuing per-leaf queries or inflating the public `session` record.
15. **Detached views have an explicit programmatic deletion API.** Deleting an attached view is rejected. Deleting an unattached view removes only its UI state and leaves its buffer untouched. No view-management GUI is part of this feature.
16. **Persistence advances to version 2 without migration.** Version-1 files are rejected with a clear version error rather than inventing occupants for formerly empty leaves. Version 2 uses buffer vocabulary and bound leaf references; live text and point remain non-restored.
17. **A view's buffer association is permanent.** A view is created for one buffer and never repointed. Changing what a leaf displays atomically detaches its current view and attaches another unattached view, preserving both view identities and points.

## Source links

All Emacs links below pin commit `541f693ca2e8de166cfe52c39bbfc497142215e9`:

- Window tree and leaf fields: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.h#L30-L176
- Window scroll/render fields: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.h#L224-L474
- Selection point swapping: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.c#L594-L614
- Window point/start primitives: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.c#L1779-L1967
- Setting a window's buffer: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.c#L4335-L4430
- Splitting windows: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/window.c#L5378-L5689
- Serializable window state: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/window.el#L6389-L6485
- Redisplay overview: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/xdisp.c#L20-L190
- Glyph matrices: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/dispextern.h#L773-L859
- Buffer file fields: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/buffer.h#L320-L516
- Elisp windows and point: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/windows.texi#L5890-L5964
- Elisp window start: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/windows.texi#L6019-L6072
