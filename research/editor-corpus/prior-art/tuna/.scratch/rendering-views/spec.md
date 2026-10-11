# Buffer views in layout leaves

Status: ready

## Goal

Complete TUNA-F-0007 by making every layout leaf display one view of one text buffer. Buffers own optional file association and live text; views own independent point state; leaves own only layout identity and the reference to the view they display.

## Scope

- Replace the speculative `subject` / `file-subject` vocabulary and public API with one buffer identity.
- Preserve the existing runtime-owned mutable UTF-8 text storage, keyed by buffer ID. “Buffer owns text” is logical ownership, not mutable storage inside immutable editor state.
- Model the in-memory values as:

  ```racket
  (struct buffer (id file))
  (struct view (id buffer-id point))
  (struct layout-leaf (id view-id))
  ```

- A view’s buffer association is permanent. One buffer may have many views.
- Every live leaf references a valid view. A view may be attached to zero or one leaf across the whole editor.
- New sessions atomically create a fresh unnamed buffer, a point-zero view, and the initial bound leaf.
- `create-view` creates an unattached point-zero view for an existing buffer.
- Creating an additional layout tree or inserting an ordinary leaf requires an existing unattached view ID for the new leaf.
- Replacing a leaf’s view atomically detaches the old view and attaches the new one.
- Removing a leaf—or deleting a tree or session containing leaves—detaches each affected view without deleting any view or buffer.
- Splitting a leaf creates a distinct view of the same buffer, initialized with the source view’s point, and attaches it to the new leaf.
- Provide programmatic deletion of an unattached view. Reject deletion of an attached view; never delete its buffer implicitly.
- Expose buffer text operations under buffer names, view buffer/point queries, point mutation, leaf view inspection, and atomic leaf view replacement. Do not retain subject-named compatibility aliases.

### Point semantics

- Point is an exact logical UTF-8 byte offset on a Unicode scalar boundary.
- Creating a view initializes point to zero. Explicit point changes reject missing buffers/views, out-of-range offsets, and non-boundaries rather than silently clamping.
- A buffer insertion, deletion, or replacement updates every view of that buffer in the same outer editor update.
- Mapping is left-biased. For replacement `[start,end)` with replacement byte length `n`:
  - points at or before `start` stay unchanged;
  - points strictly inside removed text become `start`;
  - points at `end` or later shift by `n - (end - start)`;
  - for a pure insertion (`start = end`), a point exactly at the insertion stays before the new text.
- A later view-aware editing command may explicitly advance only its source view after inserting. F-0007 does not add that command.

### Rendering

- Add a private server render query that gathers the active frame subtree, referenced view/buffer metadata, and immutable full-text snapshots under one editor lock.
- Keep `get-session` and the public session value layout-only; do not make the renderer issue separate per-leaf public queries.
- Render each leaf with its leaf, view, and buffer IDs and the buffer’s complete literal text, preserving whitespace and line breaks. Buffer text must be serialized as text, never interpreted as HTML.
- Keep active-leaf styling and all existing fit/scroll layout behavior unchanged.

### Persistence

- Advance the state-file format to version 2 and reject version 1 with a clear unsupported-version error; do not migrate old empty leaves.
- Persist buffer metadata, permanent view-to-buffer identity, detached views, and leaf-to-view references.
- Do not persist live buffer text or view point. Restored buffers start empty and restored views start at point zero.

## Non-goals

- Markers or a general edit-tracking position abstraction.
- Mark, selection, overlays, text properties, syntax metadata, modes, undo, or dirty state.
- Viewport start, horizontal/vertical text scrolling, cursor rendering, measured rows, glyph caches, or incremental rendering.
- Buffer switching history, automatic detached-view selection, MRU policy, or file-keyed saved-place behavior.
- Buffer killing, file visiting/saving, file pickers, minibuffers, tabs, mode lines, or other GUI elements.
- Reproducing Emacs’s selected-window buffer-point swapping or redisplay internals.

## Decisions

- A frame remains only a pointer into a shared layout tree. Frames exposing the same leaf expose the same view.
- Distinct leaves never share one view. They may display one buffer through distinct views.
- Views are global, reusable state objects and may outlive leaf attachment.
- View history is deferred to TUNA-F-0014; cursor/selection/viewport presentation remains in TUNA-F-0017; measured rendering remains in TUNA-F-0018.
- Full-buffer rendering is an intentionally simple first seam. Its cost is accepted until profiling demonstrates a bottleneck.
- Derived HTML, visible-end positions, browser geometry, and render caches are not authoritative view state.

## Acceptance and test seam

The highest public seam is the exported Racket API exercised together with the canonical session renderer.

Acceptance requires tests showing:

1. Buffer-named creation, text, file, location, and edit APIs replace subject-named APIs.
2. A new session begins with a valid unnamed buffer → view → leaf chain.
3. A leaf exposes its view; the view exposes its permanent buffer and point.
4. Two views of one buffer maintain independent points.
5. A view cannot be attached to two leaves, and every leaf reference is validated.
6. Leaf replacement, leaf removal, tree deletion, and session deletion detach views without deleting them; only an unattached view can be explicitly deleted.
7. Splitting clones buffer identity and initial point into a new independent view.
8. Insert/delete/replace map every affected view point with the agreed left-biased rules, including multibyte boundaries and failed outer-update rollback.
9. The server renders literal full-buffer text and leaf/view/buffer IDs while preserving recursive layout, allocation, scrolling, active-leaf behavior, and HTML safety.
10. Version-2 state round-trips buffer/view/leaf identity, restores point and text to zero/empty, and clearly rejects version 1.

## Validation

From the repository root:

```sh
make format
make test
make review
make package-test
```

## Open questions

None for TUNA-F-0007. Buffer/view reopening policy, saved places, viewport state, and interactive editing remain explicitly deferred capabilities.
