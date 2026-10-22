# Brief: drawing only what changed

**Date:** 2026-10-22. **Status:** approved 2026-10-22 (owner chose automatic recording). [ADR 17](../../agents/adr/0017-memo-and-sources.md); plan [`agents/plans/drawing-only-what-changed.md`](../../agents/plans/drawing-only-what-changed.md). Evidence is in [`agents/research/rendering/`](../../agents/research/rendering/): an audit of today's renderer with measurements, the incremental-computation prior art, how editors redraw lines, the loop and outside state, and Gerbil costs.

## What we're building and why

Every frame still sends the whole visible screen as one fat morph. That does not change. This brief is only about how cheaply the server *produces* that screen.

**What Tuna does today**
- **Reuse is per node, all or nothing.** Tuna keeps each node's HTML and reuses it when the node has not changed. A file is one big text node, so typing a letter, or even moving the cursor one character, rebuilds all the HTML of the roughly 200 lines on screen. That costs 3 ms and 10 MB of garbage per tab per key.
- **The list of inputs is written by hand, and it is already wrong in places.**
  - Line ids stop following their text in `*mixed*` (a bug the audit reproduced).
  - Rebinding any key redraws everything.
  - A renderer that reads a setting would silently show stale HTML.
- **Outside state has no proper way in.** A magit-like status buffer or a live process list has no clean path into the screen.
- **An idle editor still works.** The 2-second session save rebuilds every tab's screen just to find it unchanged.

**The goal** is one mechanism that works at every depth: for the layout, a view, any kind of node, each line of any text store, and a row fed from outside Tuna. A piece's HTML is rebuilt exactly when something it read has changed, and never otherwise.

## The idea, in three rules

1. **Everything that can change has a revision.** Each of these is a *source*:
   - buffer nodes;
   - the characters of each line;
   - the highlighting and cursors on a line;
   - keymaps and settings;
   - what a tab measured;
   - outside things such as git status or `/proc`.
2. **Every piece of the screen is drawn through one function, `memo`.** While a piece draws, Tuna notes every source it reads. Next frame, if none of those moved, its last HTML is reused untouched. Pieces nest: a view holds nodes, and a node holds lines or rows. A parent with nothing changed beneath it is reused in one check. Renderers stay ordinary recursive functions; only Tuna's accessors know about revisions. The same Lisp-style tree, drawn by the same function at every level.
3. **Lines and rows are compared by their small inputs, not by position.** A line's inputs are its text, the highlighting on it, and the cursors on it. Inserting a line leaves every other line's HTML alone. Moving one cursor redraws the two lines it left and entered; ten cursors redraw at most twenty. Rope, gap buffer, anything: the renderer only ever asks for "line *n*'s text and spans".

Around those rules:
- **Outside state is a source.** A background job reads it (`git status`, `/proc`), compares it with the last reading off the editor thread, and posts only what differs. The result updates only the rows that changed. When nothing differs, nothing is posted, so nothing is drawn or sent.
- **Asynchronous highlighting** arrives tagged with the text revision it was computed for. It is shifted through the edits made since then and redraws only the lines whose highlighting actually changed.
- **Tabs share work.** A piece that read nothing about a particular tab (most nodes and lines) is shared by every tab: Anders' "render shared parts once".
- **Idle is truly idle.** Each owner of visible state keeps a change count, and a redraw for a tab where none moved does nothing. Session saving runs after a change instead of every 2 seconds.
- **Pieces are written straight into the stream as bytes,** not glued into one big string first. Measured on a 35 KB screen: 0.3 ms today, 0.005 ms this way.
- **The kernel does not change.** The pieces live in the renderer, buffers and web plugins, a small `memo` library, and the jobs library.

## The picture

**Status:** planned.

![What each piece of the screen depends on](../diagrams/memo-pieces-and-sources.svg)

![One second of a live process list](../diagrams/memo-process-list-second.svg)

## A walkthrough

You have a 50,000-line file open on the laptop and the phone, with a live process list in a second view.

1. **You type `x` on line 25,000.** The text records the change: line 25,000 replaced. Next frame, the view's frame and status line are rebuilt; they are tiny. The text node asks each drawn line whether its inputs changed. Only line 25,000's did, so one line is drawn and about 200 are reused. The phone gets the same line from the shared pieces.
2. **Highlighting comes back a moment later** for the revision you typed at. It is shifted past any newer edits. Line 25,000's colours changed, and so did the next three, because you opened a string. Those four lines are redrawn; the rest stay.
3. **You press `C-f`.** The cursor moves within line 25,000, so that one line is redrawn.
4. **You add cursors on three more lines.** Those three lines are redrawn.
5. **The process list ticks.** The job reads `/proc` and two of 200 processes changed CPU. It posts two changes, two row nodes get new revisions, two rows are drawn, and 198 are reused.
6. **You stop.** Nothing posts and nothing changes, so no task runs, no screen is built and no bytes are sent.

## A code sample (package author's view)

```scheme
;; A process row draws only from its own node. Tuna notes what it reads,
;; so a row is drawn again exactly when its attributes change.
(context-define-node-renderer! ctx 'process-row
  (lambda (row)
    `(div (@ (class "process-row"))
       (span (@ (class "pid")) ,(node-attribute row 'pid))
       (span (@ (class "cpu")) ,(node-attribute row 'cpu))
       (span (@ (class "command")) ,(node-attribute row 'command)))))

;; Outside state: read /proc every second off the editor thread, and post
;; only the rows that differ from last time.
(context-start-source! ctx 'processes
  every: 1.0
  read: read-processes                ; -> plain data, one record per pid
  apply: (lambda (changes) (update-rows! table changes)))
```

Emacs's `proced` erases and reinserts every row each refresh. Here the rows keep their identity, so point, folds and their HTML survive. Names are illustrative.

## Decision for the owner

**Should Tuna note what each piece reads automatically, or should each renderer list its own inputs?**

- **Context.** Today the inputs are listed by hand: the node's revision, point, face remapping and the keymap generation. The audit found that list already misses things. Hyperlith also keys its components by hand, but Hyperlith's components read one database. Tuna's renderers read many kinds of mutable state.
- **Automatic tracking (recommended).** Every read goes through Tuna's accessors, which note it at about 29 ns per read (measured). A test mode fails any renderer that reads state behind Tuna's back. It cannot drift. It covers outside sources the same way, and it decides by itself which pieces tabs can share.
- **Hand-written keys.** Less machinery, but every renderer author must remember every input, and a mistake shows stale screens. That is the bug class we have now.
- **Recommendation: automatic.** It is the only way the mechanism stays generic as plugins multiply, and it costs a few nanoseconds per read.

Settled without asking, because the evidence decides them:
- **Lines are compared by value**, not tracked through a line-number shadow. It is simpler and works for any store, at the cost of reading each drawn line's text every frame, which drawing does anyway.
- **No Merkle hashes.** Revisions already say what changed. Hashes only pay when equality must hold across machines.
- **The proof is a `proced`-style process-list plugin.** It must show that rows drawn equals rows changed, and that 60 idle seconds cost zero tasks, zero screens and zero bytes beyond heartbeats.

## Limits and later work

- **A single huge line**, such as minified JavaScript, is one item, so a key in it redraws all of it. Splitting long lines into chunks is later work, as Emacs, VS Code and Zed all handle it specially.
- **Gerbil's SXML writer is the biggest remaining cost** of building HTML: 1.26 ms for 100 lines, against 0.08 ms writing directly. Your typed XML module replaces it.

## New terms

- **Source:** anything a screen can depend on, with a revision that changes when it does.
- **Piece:** any part of the screen with its own HTML: the screen, a view, a node, a line, a row.
- **`memo`:** draws a piece, or reuses its last HTML when nothing it read has changed.
