# Tuna structured-buffer research

Status: research supporting the [buffer-model proposal](../plans/tuna-buffer-model/spec.md), not implementation authorization. Investigated 2026-10-03 with three read-only subagents and two focused follow-ups; the parent reconciled their advice with the owner's answers. No browser experiments or builds were run.

## Result

Tuna can make structured content authoritative while retaining ordinary text operations at every text-bearing leaf. The gap buffer should remain a private character-storage implementation, not the owner of structure, properties, overlays, navigation, file policy, or user history. HTML is one renderer's output, not the buffer's representation.

The owner settled these constraints during this investigation:

- Browser tabs mirror one shared editor, including cursor, selection and focus, like attaching to one tmux session. There is no independent browser-tab workspace or navigation state.
- Public text positions count Unicode code points from zero.
- The first text store is a gap buffer; its public interface must permit a later rope or piece-tree implementation.
- Editing is terminal-style Command Query Responsibility Segregation (CQRS): input goes to the server, which owns committed state and produces updated HTML. No input, textarea, or browser-owned contenteditable editor.
- Rich properties and overlays must be renderable in the first usable editor.
- Ordinary typing comes first. Full Input Method Editor (IME), dead-key and mobile-keyboard acquisition is deferred, with a future committed-text input seam.
- Recovery may be added later; whole-workspace serialization is not a prerequisite.
- Names are proposals, not owner commitments. Keep the initial structural vocabulary small; do not build Magit or a widget framework.

## Current repository facts

The current Tuna checkout is `/home/jay/Code/workbench-gerbil/tuna`, at `bf7860533738e6c1e162c9ae019b53f5654287da` after the owner's frontend commit. The investigated frontend and input slice are now committed rather than merely staged working-tree changes.

`frontend/tuna-keyboard.ts` serializes keydown POSTs without automatic retries. `tuna/server.ss` validates admission, writes a bodyless 204 and enqueues the event; this acknowledges receipt, not command success. `tuna/input.ss` resolves and runs commands serially, catches failures, and currently recognizes only an Enter greeting command. `tuna/main.ss` wires the worker and localhost HTTP server. The GET stream currently publishes an initial body, then waits for shutdown. There is no editor-state publication, logical buffer, text store, file lifecycle, or node-rendering protocol in this slice.

The existing input worker is an ordering mechanism, not an established editor-state architecture. The proposal must add explicit state ownership and stream fan-out rather than silently treat the queue as a transaction system. A single consumptive channel must not be shared by several stream subscribers: subscribers need their own latest-publication notification.

`../tuna-support/docs/customization.md` documents live ordinary bindings but specialized native constructors/accessors/methods. Reloadable renderer and command behavior should therefore live in ordinary procedures above native storage, with methods delegating to those procedures where live replacement is desired. Re-evaluating a plain hook definition creates a new hook; reload-stable declarations are still planned. Existing customization performance issues are unrelated evidence, not permission to repair or gate this buffer work on them.

## What the Emacs evidence establishes

Emacs's `buffer_text` holds the character array/gap, text-property intervals, marker chain and modification counters. Its larger `buffer` holds or references navigation, overlays, locals/modes, file metadata, undo and display state. Indirect buffers share characters and text properties while retaining separate buffer-level state. This is evidence for separating text storage from editor semantics, not a mandate to implement indirect buffers in Tuna.

Text properties and overlays are different mechanisms. Text properties accompany copied text; overlays do not. Property changes participate in Emacs modification/undo machinery; overlay changes normally do neither. Plain-file serialization does not serialize arbitrary character properties. Tuna should distinguish logical modification, file-relevant modification and transient rendering invalidation rather than use one ambiguous dirty bit. Emacs self-inserting typing uses inheritance, ordinary programmatic insertion defaults to none, and competing sticky values prefer the preceding character; the proposal follows that documented precedence.

Emacs autosave is a separate file-lifecycle facility, normally writing recovery files instead of overwriting the visited file. It does not require serializing every buffer-local value, overlay or window. It can be planned as a later file-service milestone without making the initial content tree persistent.

Primary sources:

- [Buffer internals](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Internals.html).
- [Pinned `buffer.h`](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/buffer.h), particularly lines 237–304, 355–390, 603–630 and 718–745.
- [Text properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html), [stickiness](https://www.gnu.org/software/emacs/manual/html_node/elisp/Sticky-Properties.html), [overlay properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlay-Properties.html).
- [Markers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overview-of-Markers.html), [narrowing](https://www.gnu.org/software/emacs/manual/html_node/elisp/Narrowing.html), [undo](https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html), [autosaving](https://www.gnu.org/software/emacs/manual/html_node/elisp/Auto_002dSaving.html).

Magit already has a hierarchy of section objects associated with ranges of its linear buffer. Tuna's distinction is making such structure part of its general buffer representation and rendering it without a mandatory line-oriented flattening: [Magit section creation](https://docs.magit.vc/magit-section/Creating-Sections.html).

## Rendering findings

The [owner's CSS-only custom-element article](https://dev.to/stuffbreaker/css-only-custom-elements-go6) contributes useful ideas: meaningful styling vocabulary, CSS custom-property tokens, low-specificity selectors and progressive enhancement. However, custom tag names have no implicit accessibility semantics. A `slot` attribute outside shadow DOM is merely a styling convention; CSS reordering changes visual order without changing reading/focus order. Prefer native semantic HTML inside any narrowly justified custom layout wrapper; do not use custom tags as substitutes for native controls or claim they provide semantics.

Read the `html-css` skills at `/home/jay/Code/shux/.agents/skills/html-css/SKILL.md`, `/home/jay/Code/job-getter/.agents/skills/html-css/SKILL.md`, and `/home/jay/Code/lipstink/.agents/skills/html-css/SKILL.md`. Transfer semantic markup, accessibility, stable morph identities, logical ordering, low specificity and token discipline. Do not transfer Stellar, Stario, their feature-specific transport policies, class-first preferences, or unrelated JavaScript approval rules into Tuna.

The node model needs target-neutral meaning and ordering. Each node can implement rendering by asking an explicit rendering context to emit its semantic role. HTML-specific element selection, escaping, attributes and CSS belong in the HTML context. A test renderer can prove this separation without implementing a terminal UI now.

Primary sources: [WHATWG custom elements](https://html.spec.whatwg.org/multipage/custom-elements.html), [HTML semantics](https://html.spec.whatwg.org/dev/semantics.html), [Datastar attributes](https://data-star.dev/reference/attributes). Tuna embeds Datastar 1.0.2 in `tuna/server.ss`; behavior must be checked against that actual asset, not assumed from a newer reference page.

## Input findings and limitations

Keyboard events describe keys and commands; they are not a complete committed-text protocol. A server fallback can insert ordinary printable key values, but must not interpret named keys, `Dead`, `Process`, `Unidentified`, or composing events as text. Full IME and mobile text acquisition require a real OS/browser text-input bridge. The owner chose to defer those features rather than adopt a textarea.

EditContext is a possible later bridge on supported non-contenteditable HTML elements. It entails transient OS/browser composition and selection state even if committed editor text and rendering stay server-owned. Its availability and morph interaction require target-specific experiments; no cross-browser guarantee was established here.

Clipboard and pointer interaction need a browser adapter, not a browser-authoritative document. Clipboard events may provide plain text during a user gesture; the current keyboard handler's blanket `preventDefault` can prevent those events. Copy/cut must use the latest committed server selection, and cut must not delete text if that selection has changed. Pointer input needs a server-generated DOM-to-model source map and revision validation. None of those behaviors has been demonstrated by browser tests in this task.

Primary sources: [keyboard key values](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/key), [keydown/composition](https://developer.mozilla.org/en-US/docs/Web/API/Element/keydown_event), [Input Events Level 2](https://www.w3.org/TR/input-events-2/), [EditContext](https://developer.mozilla.org/en-US/docs/Web/API/EditContext), [host attachment](https://developer.mozilla.org/en-US/docs/Web/API/HTMLElement/editContext), [clipboard specification](https://www.w3.org/TR/clipboard-apis/), [paste](https://developer.mozilla.org/en-US/docs/Web/API/Element/paste_event).

## Advice not adopted as requirements

- Independent per-tab views conflict with the owner's shared-session decision.
- A textarea-first editor conflicts with the explicit rendering/input decision.
- A command-only prototype must not be called a usable editor; the ordinary-printable-key fallback and clipboard path still need tests.
- Omitting all property inheritance is not forced by the evidence. The proposal specifies inheritance explicitly and retains familiar interior-run behavior.
- Deferring property and overlay rendering conflicts with the owner's first-usable-editor requirement.
- Avoiding every target-neutral layout hint is unnecessary: ordered row/stack composition can describe structure without encoding HTML or CSS.
- Old SumTree/gap/rope benchmarks do not establish Gerbil performance. Benchmark actual editing, history, anchors and rendered projections.

## Proposal review

A fresh read-only reviewer found two concrete contract gaps, both addressed in the proposal: opposed overlay endpoint affinities can cross under replacement, so a surviving overlay needs an explicit collapse/point policy; and a fresh HTML projection does not fence delayed input, so uncertainty recovery needs a shared admission epoch and an owner-ordered fence before input resumes. These corrections do not introduce independent tab state, native input elements, retries or persistent command replay. The focused reviewer recheck confirmed both corrections and found no remaining proposal blockers; implementation and browser/runtime experiments remain unvalidated.

## Remaining experimental work

Prove the actual HTML-only surface's ordinary keyboard input, clipboard delivery, pointer mapping, screen-reader behavior and morph stability in supported browsers. Prove transaction cancellation and nonlocal-exit handling with the installed Gerbil toolchain. Measure character-to-byte conversion, annotation remapping, undo retention, very long lines, and complete edit-to-render costs before claiming large-file interactivity. These are implementation evidence requirements, not settled performance facts.
