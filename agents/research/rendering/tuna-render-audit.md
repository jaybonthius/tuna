# Research: Tuna's rendering pipeline today, and where generic HTML memoization would attach

Audit of `tuna` at `e972004` (2026-10-22). Nothing in the repository was edited. Experiments ran on a `git archive` copy built in `/home/jay/Code/workbench-gerbil/scratch/rendering-audit/` (Gerbil v0.19-dev-63-g1cfb032c, 16 cores). Paths are relative to the `tuna` checkout unless shown absolute.

Labels used below:
- **Fact (code):** read in the cited source.
- **Fact (measured):** produced by the scratch benchmarks.
- **Inference:** the auditor's reasoning; not stated by any source.

## Summary

Today a redisplay renders one screen per open tab. The cache is per tab, per view and per **node**: a node's HTML string is kept, together with its revision, its view state, its renderer and two display-wide inputs. Inside a node nothing is cached, so in `*long*` (a buffer that is a single text node) every keystroke and every point motion rebuilds the HTML of every drawn line: about 3 ms and 10 MB of allocation per tab at 226 lines, and about 6 ms when the demo's digit highlights are present. Every screen then goes over the wire whole: about 53–61 KB.

The current key misses several inputs that are hazards for any finer memo:
- Line-id pins are dropped under reused ancestors. This was reproduced.
- Each line's `data-item` token embeds the text's revision.
- Renderers may read state the key does not capture; nothing enforces the rule against it.
- Highlight layers carry no information about which range changed.

The change information a per-line memo needs (change records with positions) already exists in the buffers contract's journal, independent of the text store. The `TextStore` contract itself exposes no change information.

### Summary table

| Question | Today | Evidence |
|---|---|---|
| Path to the wire | Kernel `redisplay` → web `redisplay!` → `Renderer.render-screen` once per tab → `render-layout` → `render-view` → `render-node` (kept HTML or the kind's renderer) → `write-sxml` strings → `string=?` against the tab's last screen → writer thread: `stamp-applied`, `patch-elements` (split into lines, framed), UTF-8 write, flush | §1 |
| Unit of reuse | One node's HTML, per (tab, view, node id) | `plugins/renderer/plugin.ss:81-116`, `:183-212` |
| Cache key | Node revision, view state (point and selected flag on the focus path; item run; line-id offset), renderer identity (`eq?`), inputs `(face-remapping . keymap-generation)` | `plugin.ss:188-198`, `:462` |
| Inside a text node | Nothing is reused: all drawn lines are rebuilt whenever the node misses | `plugin.ss:234-279` |
| One key in `*long*` | Whole drawn text node rebuilt (the root is the text node; it was stamped) | Fact (measured): 2.9 ms render, 10.5 MB allocation, 53.5 KB frame at 226 lines |
| C-f in `*long*` | Same full rebuild: point is in the key of the focus path | 2.9 ms, 53 KB |
| One key in `*mixed*` | Edited text node, its block and the root are rebuilt; siblings are reused; the root's item count is recounted over 4,000 children | 2.1 ms render, of which 1.6 ms is `node-item-count` |
| Idle redisplay | Every node reused; layout, view chrome and the screen string rebuilt; identical screen not sent | 0.2–0.7 ms render (1.0 ms at 400 items); 0 bytes |
| Several tabs | Cost is linear: nothing is shared between tabs | 2 tabs = 2× render |
| Change information | Global node revisions stamped up to the root; text chars, content and decoration revisions; a journal of change records (`start`, `removed`, `inserted`), 1,000 deep (the toy buffers provider: 100); `after-change-hook` | §4 |
| Line-level change info from `TextStore`? | No. Only versions; the journal in the buffers layer has it | `plugins/text-store/contract.ss:14-32` |
| Main hazards | Pins dropped under reused ancestors (reproduced); revision-bearing tokens; unenforced "render only from node" rule; whole-layer highlight replacement; side effects during render | §6 |

## 1. From a redisplay to bytes on the wire

All Fact (code):

1. **Kernel loop.** A dispatched input, a task or a job result sets `loop.dirty?` (`tuna/kernel/loop.ss:404, 416, 419`). `run-ready!` redisplays when nothing has higher priority, or at least every 0.1 s under sustained input (`redisplay-cap`, `:156`; `redisplay-due?`, `:385-386`; `run-ready!`, `:391-409`). `redisplay-now!` clears the flag and calls `redisplay` (`:427-436`), which calls the Display provider's `redisplay!` (`:273-275`). The kernel does not know about screens or tabs.
2. **Web transport, editor thread.** `{redisplay! web-server}` (`plugins/web/plugin.ss:195-205`):
   - renders the stylesheet head only when the registry changed;
   - collects every tab with a stream open, or one wanting a screen;
   - calls `render-screen tab.client` once per tab (`:154-158`).

   `publish-screens!` (`:215-229`) compares each result with the tab's last screen by `string=?` (`:223`). Only a different screen, or one the tab is owed, gets a revision. Stamping it (`stamp-revision`, `:169-170`, through `add-root-attributes`, `:181-190`) copies the whole string. A page load or a new stream asks for a redisplay through a keeper thread, which spawns an empty `tab-screen` task (`:563-577`).
3. **Renderer** (`plugins/renderer/plugin.ss`):
   - `render-screen!` (`:498-510`) picks the tab's table of views (`clients`, weak keys, `:104`) and calls the layout's `render-layout 'html` with a `render-view` callback.
   - It drops kept HTML of views not drawn (`:508`).
   - It serializes the whole screen with `html-string` = `write-sxml` into a string port (`:156-158`, `:510`).
4. **Layout** (`plugins/layout/plugin.ss:886-897` → `render-html`, `:468-485`) builds SXML for its containers (`render-fit`, `:83-84`; `render-tabbed`, `:91-108`, which also reads `part-clickable?`). It calls `render-view` for each visible view. Layout HTML is never cached.
5. **View** (`render-view`, `plugin.ss:448-496`):
   - reads the tab's `client-view` (`view-client`, `plugins/buffers/contract.ss:1134-1141`, which creates one when missing);
   - computes the drawn item run from the measured scroll item and the drawn-before/after counts;
   - builds the `drawing` (kept table, focus path, view state, inputs, pins);
   - emits SXML for the view section, the scroller attributes (`:357-372`), the placement marker (`:379-390`), the spacers (`:409-422`), the scroll sizer (`:438-443`) and the status line (`status-line-text`, `plugins/renderer/contract.ss:47-60`).

   None of these view-level parts is cached. Afterwards it copies the kept entries for every drawn node into a fresh table and replaces the pins with this drawing's pins (`:486-496`).
6. **Node** (`render-node`, `plugin.ss:183-212`):
   - It looks up the kept HTML by node id. A hit returns `(*unencoded* html)`.
   - On a miss it renders the drawn children first (`drawn-children`, `:168-178`), then calls the kind's renderer with the children as opaque `*unencoded*` fragments. A kind without a renderer gets a `div` with its text projection.
   - It adds ids and data attributes (`with-node-id`, `:141-154`) and serializes the node to a string with `write-sxml` (`:202-209`).

   So every re-rendered ancestor copies all of its drawn descendants' HTML once more.
7. **Text nodes** (`render-text-node`, `:234-279`):
   - It filters **all** highlight spans of the text (`text-all-highlights`) down to the drawn range.
   - For each drawn line it reads the start, end and substring through the buffers contract into the text store, filters the spans again, and builds the `line` element (`render-line`, `:284-315`: a face vector per character, runs, and the cursor).
   - It adds a `data-item` token (`item-token`, `contract.ss:823-835`) and a line id (`:272-277`).
8. **Writer thread, one per stream** (`stream-screens`, `plugins/web/plugin.ss:609-640`).
   - `await-screen` (`:255-278`) hands it the newest screen once the page confirmed the previous one.
   - It then:
     1. copies the screen again (`stamp-applied`, `:174-178`);
     2. calls `patch-elements` (gerbil-datastar `http/private/core.ss:381-417`), which checks for control characters, splits the screen into lines (`split-lines`, `:46-55`, one substring per line) and builds a frame string with `with-output-to-string` (`event-frame`, `:360-375`);
     3. writes the frame as UTF-8 through a `BufferedWriter` and flushes (`gerbil-sse/sse.ss:40-56`).
   - The stylesheet head goes as a separate `patch-elements` when it changed (`:631`).
   - Heartbeats are `patch-signals "{}"`. No compression.

**String building summary** (Fact (code)):
- Strings are built at every node miss (`write-sxml` per node) and once per screen (`render-screen!`).
- The transport then makes about four more whole-screen copies: `stamp-revision`, `stamp-applied`, the `split-lines` substrings, and the frame.
- Concatenation happens through `write-sxml`'s handling of `*unencoded*` and through `string-append`.

## 2. What is cached, keyed by what; what one keystroke recomputes

**Structure** (Fact (code), `plugin.ss:81-116`):
- `html-rendering.clients`: client (or `#f`) → view id → `view-html { start node; nodes: node id → kept-html; pinned-ids: text node id → line-ids }`.
- `kept-html` = `{revision, view-state, how, inputs, html}`.
- `view-html-for` empties a view's table when it is drawn from a different start node (`:332-338`).
- The `client-gone-hook` drops a tab's tables (`:524-525`).

**The key** (`render-node`, `:186-198`). A kept entry is reused when all of these hold:
- `revision` = `node-revision n`. Revisions are global `next-id!` values stamped on a node and all its ancestors (`plugins/buffers/plugin.ss:214-229`).
- `view-state` is `equal?`. It is a list of three parts:
  1. `(point . selected?)` if the node is on the path from the buffer root to the view's focused text node, else `#f`;
  2. the node's item run (`#f`, `'item`, or `(first . last)`);
  3. the line-id offset when the node is drawn as lines.
- `how` is `eq?`: the registered renderer procedure, or the kind info when there is none.
- `inputs` is `equal?`: `(cons (buffer-local-value face-remapping b) (keymap-generation))`, built per view at `:462`.

**Reused vs recomputed.**
- Fact (code): a node is reused only if every component matches.
- Fact (code): on reuse its descendants are not visited; their entries are carried over by the keep loop (`:489-495`). Their pins are not (see H1).
- Fact (code): everything above nodes is rebuilt each redisplay: layout, view chrome, spacers, sizer, marker, status line and the screen string. So is `node-item-count` of the start node, which is cached per node revision in `children-items-kept` (`contract.ss:685-721`).

**One keystroke** (self-insert; Fact (code) plus Fact (measured), §5):

**`*long*`** (`demo/long-buffer.ss`; the buffer root *is* the text node):
- `text-replace!` stamps every node that refers to the text, and their ancestors (`plugins/buffers/plugin.ss:70-85` → `stamp-nodes!`).
- The start node's revision changed, so the miss rebuilds every drawn line: 226 lines at 90/135 drawn.
- Each line's HTML also differs from before. Its token `N.P.R` embeds the chars revision `R`, and the start position `P` shifts for lines after the edit (Fact (measured): a line after typing is `<div class="line" data-item="150.3571849.60" id="view-26-node-150-line-24910">…`).
- So the whole frame changes, about 53 KB.

**C-f in `*long*`:** no stamp, but point is in the focus path's view state, so the same full rebuild happens. Only one or two lines' cursor actually changed.

**`*mixed*`** (`demo/mixed.ss`; root `mixed` → 4,000 children; paragraphs and code blocks wrap a text node):
- The edited text node, its `mixed-code`/`mixed-paragraph` block and the root miss. Siblings are reused (Fact (measured): renderer call counts per key are `mixed` ×1 and `mixed-code` ×1, and no other kind).
- Re-rendering the root copies every drawn sibling's kept HTML into the root's new string.
- The root's changed revision forces `children-items-of` to recount all 4,000 children's items through service dispatch: 1.6 ms of the 2.1 ms render (Fact (measured)).
- C-f also re-renders the root and the block, because point is part of the focus path's key: 0.36–0.5 ms.

## 3. Every input the renderer reads, and whether the key captures it

"Captured" means a change to the input changes the reuse key of every kept HTML that depends on it.

| Input | Where read | Captured? | Notes |
|---|---|---|---|
| Node kind, attributes, children, keymap object | Kind renderers; `with-node-id` (`plugin.ss:141-154`) | Yes, by revision: `set-attribute!`, `set-children!` and `set-keymap!` stamp (`buffers/plugin.ss:265-282`) | Fact (code) |
| Text characters | `render-text-node` | Yes: the edit stamps the text's nodes (`buffers/plugin.ss:84`) | Fact (code) |
| Highlight spans (all layers) | `text-all-highlights` (`plugin.ss:248-254`) | Yes: `set-layer!` stamps (`buffers/plugin.ss:160-168`); an edit relocates spans (`:174-180`) under the same stamp | Replacing a layer with identical spans still stamps and fully re-renders (Fact (measured): 5.6 ms producing an identical screen) |
| `face-remapping` (buffer-local) | `remapped-face` (`renderer/contract.ss:40-42`) | Yes: in `inputs` | Fact (code) |
| Keymap bindings (`data-clickable` on nodes) | `keymap-clickable?` (`keys/contract.ss:315-316`) | Yes: by the global `keymap-generation` (`keys/plugin.ss:380-389`) | Over-invalidates: any rebind repaints every node (TODO.md) |
| Point of the view | `render-text-node` `view-point` (`plugin.ss:238`) | Yes, for focus-path nodes: `(point . selected?)` | Also forces every ancestor and every line of the focused node to miss |
| Selected view (cursor class) | `(selected-view)` (`plugin.ss:239`) | Indirectly: `selected?` is in the focus-path state, and the cursor shows only in the focus node | Safe only because of that coupling. Inference: another renderer reading `selected-view` would go stale |
| Other selections, mark, region | Not rendered today | n/a | ADR 6 defines a selection list; any future rendering must enter the key |
| Drawn item run (client measurements: scroll item, drawn before/after) | `render-view` (`:452-467`) → `drawn-children`, `render-node` | Yes: the run is in the view state | Fact (code) |
| Line-id pins (offset) | `pin-line-run!` (`:217-229`) | Yes for the text node (offset in its state). **Not** in its ancestors' keys | Hazard H1 |
| Text chars revision inside `data-item` tokens | `item-token` (`contract.ss:823-835`) | Yes, via the node revision (same edit) | Makes every line's HTML change on every edit (H6) |
| Element ids (view id, node id) | `with-node-id`, `view-element-id` | Yes: the table is per view; ids are stable | Fact (code) |
| Kind renderer procedure / kind info | `node-renderer`, `node-kind-ref` (`plugin.ss:185-186`) | Partly: `eq?` on the registered procedure | Changes inside helpers it calls are invisible (H3) |
| `node-opening` / kind `items:` | `drawn-children`, `item-run` | Indirectly, through the run | Fact (code) |
| Status line: buffer name, line/column, `current-task-name` | `status-line-text` (`renderer/contract.ss:47-60`) | Not cached; rebuilt every redisplay | No hazard |
| `show-status-line`, `drawn-screens` (buffer-local) | `render-view` (`:482`), `scroller-attributes` (`:341-343`) | Not cached; rebuilt every redisplay | No hazard |
| `part-clickable?` (status line, tabs) | `render-view` (`:485`), `render-tabbed` | Not cached | No hazard |
| Measured facts, average item height, newest placement | `scroller-attributes`, `spacer`, `scroll-sizer`, `placement-marker` | Not cached | No hazard |
| Layout tree, frame, selected container | `render-html` (`layout/plugin.ss:468-485`) | Not cached | No hazard |
| Stylesheets | Web head (`web/plugin.ss:197-199`) | Separate: sent only when changed | Not part of the screen |
| Echo area message, minibuffer prompt, completion rows, help | Node attributes and text in their buffers (`echo-area/plugin.ss:51-53`, `minibuffer/plugin.ss:219-222`, `completion-vertical/plugin.ss:114-121`) | Yes, by revision: the plugins write node attributes or children | Completion rebuilds its row nodes on each `present`, so new ids mean no reuse |
| Settings other than `face-remapping` (global or buffer-local) | None of today's node renderers read one (Fact (code), all `context-define-node-renderer!` call sites) | **No** | Hazard H2 if a renderer reads one |
| State outside Tuna (git, processes, time) | None today | **No** | H2; the only safe channel today is writing node attributes or children (which stamps) |

The ADR 13 "Stage 3 additions" and the renderer header (`plugin.ss:54-65`) describe the contract: "a node renderer must draw only from its node, its children's renderings … and those inputs". It is a convention: nothing records or checks what a renderer reads (Fact (code)).

## 4. Change information available today

All Fact (code):

- **Node revisions:** one global counter (`next-id!`), stamped on the changed node and every ancestor (`stamp!`/`stamp-from!`, `buffers/plugin.ss:214-224`). One edit to a text stamps every node referring to it (`stamp-nodes! t.nodes`, `:226-229`, `:84`). Nodes reattached after detaching are re-stamped (`:232-240`). A revision says "this subtree changed", not what or where. The toy buffers provider does the same (`plugins/buffers/tests/support/toy-buffers.ss:178-184`).
- **Text revisions:** `text-chars-revision` (the snapshot revision, `contract.ss:400-401`), `text-content-revision` and `text-decoration-revision` (Buffers interface, `:316-317`). `set-layer!` bumps the decoration revision. An edit bumps chars and content but not decoration, although it relocates spans.
- **Journal and change records:** `change {revision, start, removed, inserted}` (`contract.ss:128-132`).
  - Default provider: the newest 1,000, trimmed to 500 (`buffers/plugin.ss:40, 87-95`). Toy provider: 100.
  - `text-changes-since t r` returns the records, or `#f` when the journal no longer reaches `r` (`contract.ss:413-414`; `buffers/plugin.ss:97-106`).
  - `relocate-position` relocates through it (`:509`).
  - `after-change-hook` runs per change with `(t c)` (`contract.ss:391-392`, `buffers/plugin.ss:85`).
- **Decorations:** `set-highlights! t name spans` replaces a whole layer (`contract.ss:518`; `set-layer!`, `buffers/plugin.ss:160-168`). No changed range is recorded or derivable except by diffing span lists. On an edit, `relocate-decorations!` maps every span of every layer (`:174-180`): O(spans) per keystroke (0.8 ms with 50,000 digit spans, Fact (measured)).
- **Derived caches:**
  - `children-items-kept`: per node, by revision (`contract.ss:685-721`).
  - Kept HTML: per tab, view and node.
  - Line-id pins: per tab and view.
- **`TextStore` contract** (`plugins/text-store/contract.ss:14-32`): `from-string`, `size`, `line-count`, `slice`, `line-at`, `line-start`, `for-each-chunk`, `replace`.
  - It has no diff, version comparison or changed-range operation.
  - Chunks "may be shared" between versions; this is not guaranteed. The toy store's versions are whole strings and its `for-each-chunk` slices a copy (`tests/support/string-text-store.ss:44-54`).
  - So the store **cannot** tell which lines changed in a store-independent way.
- **Is that enough for per-line work?**
  - Inference: yes for characters. A change record's `start`, `removed` and `inserted` map, through `text-line-at` and the newlines in `removed`/`inserted`, to the lines touched and to a line shift after them.
  - This works identically over the rope and the toy store, because it lives in the buffers layer.
  - Not for decorations (whole-layer replacement) or for any input outside the text.
  - Not past the journal's horizon, where `text-changes-since` returns `#f` and a full redraw is needed.

## 5. Measurements

**Method:**
1. **In-process benchmark.** `/home/jay/Code/workbench-gerbil/scratch/rendering-audit/bench/bench.ss`, built with `build.sh` (`gxc -O`; the Tuna libraries come from a plain `gerbil build` of the archived copy). It runs a fresh kernel with commands, keys, rope text store, settings, a no-op session, buffers, layout, the HTML renderer, echo area and minibuffer. The `*long*` text and `*mixed*` tree come from copies of the demo modules; the `*mixed*` copy only counts renderer calls.
   - Client views are set directly: drawn 90 before / 135 after (*inference*: about two screens of a 900 px view at about 24 px per line), or 200/200 (the count before any report, `initial-drawn-items`). Average item height 24 px.
   - Point and the scroll item: line 25,000 in `*long*`; section 1,000 ("middle") or the top in `*mixed*`.
   - Medians of 30 runs from `##exec-stats`.
   - "Transport strings" repeats the web plugin's `stamp-revision` and `stamp-applied`, and gerbil-datastar's line split and frame build, on the rendered screen. It excludes the socket write.
   - Raw output: `bench/run4.txt` (also `run2.txt`, `run3.txt`).
2. **End to end over HTTP.** `/home/jay/Code/workbench-gerbil/scratch/rendering-audit/http-client.py`, run by `run-http.sh`. It drives `.gerbil/bin/tuna --port 18731 --config demo/init.ss` as a tab: loads the page, opens the SSE stream, posts `/applied` as a page does, then posts keys (C-c g or C-c M, then 60 keys).
   - Run with `XDG_STATE_HOME` in scratch, under the required memory cap. The process was stopped by its exact PID.
   - No scroll reports are sent, so drawn counts stay 200/200.
   - Raw output: `http-run1.txt` to `http-run3.txt`.

**In-process, per redisplay and per tab** (Fact (measured), `run4.txt`):

| Scenario | State change | Render (median) | Render allocation | Transport strings | Frame bytes | Lines drawn |
|---|---|---|---|---|---|---|
| `*long*` 90/135, idle | — | 0.33 ms | 1.3 MB | (identical screen: real transport only compares it with `string=?`) | 53,282 | 226 |
| `*long*` 90/135, C-f | 0.005 ms | 2.93 ms | 10.5 MB | 0.29 ms | 53,283 | 226 |
| `*long*` 90/135, key | 0.02–0.04 ms | 2.89 ms | 10.5 MB | 0.28 ms | 53,526 | 226 |
| `*long*` 200/200, key (`run2.txt`) | 0.04 ms | 5.49 ms | 18.2 MB | 0.49 ms | 94,263 | 401 |
| `*long*` + 50,000 digit spans, C-f | 0.006 ms | 5.57 ms | 18.1 MB | 0.32 ms | 60,774 | 226 |
| `*long*` + digits, key | 0.82 ms (span relocation) | 5.62 ms | 14.4 MB | 0.33 ms | 60,791 | 226 |
| `*long*` + digits, same layer re-applied | 177 ms (includes computing the spans) | 5.63 ms, **identical screen** | 12.6 MB | — | 60,805 | 226 |
| `*mixed*` top 30/45, idle / C-f / key | — / 0.003 / 0.02 ms | 0.20 / 0.36 / 2.06 ms | 0.7 / 1.2 / 2.5 MB | 0.06 ms | 10.4 KB | 31 |
| `*mixed*` middle 30/45, idle / C-f / key | — / 0.004 / 0.014 ms | 0.26 / 0.51 / 2.15 ms | 0.8 / 1.8 / 3.1 MB | 0.10 ms | 18.5 KB | 45 |
| `*mixed*` middle 200/200, idle / C-f / key | — | 0.69 / 1.60 / 3.34 ms | 2.0 / 5.3 / 6.6 MB | 0.44 ms | 85 KB | 215 |
| `*mixed*`: `node-item-count` of the root after one edit | — | 1.6 ms, 1.3 MB (0.002 ms unchanged) | | | | |
| Two tabs (any scenario) | — | the same per tab, twice the calls | | | | |
| `write-sxml` copying one finished 53 KB screen string | — | 0.08 ms, 0.9 MB | | | | |

Notes on the in-process numbers:
- Render dominates. Within it, the text node's per-line work dominates in `*long*` (about 13 µs and 46 KB of allocation per drawn line), and the item recount dominates in `*mixed*`.
- State changes cost microseconds, except span relocation with a big highlight layer.
- The transport's string work is about 10% of render.
- GC per render in-process averaged 0.1–0.8 ms. The heap there is small.

**End to end over HTTP** (Fact (measured), `http-run3.txt`; run 1 is similar, run 2 noisier):

| Scenario | Wall time, key posted → screen received (median) | Server CPU per key (process total over 60 keys, 10 ms clock ticks) | Bytes per key | Screens per key |
|---|---|---|---|---|
| `*long*` key (201 lines drawn) | 9.1 ms (run 1: 9.8; run 2: 37.1) | 60.7 ms (run 2: 64.2) | 52.7 KB | 1.00 |
| `*long*` C-f | 7.3 ms | 27.0 ms | 52.8 KB | 1.00 |
| `*mixed*` key, top (130 lines among the drawn items) | 6.7 ms | 8.5 ms | 35.5 KB | 1.00 |
| `*mixed*` C-f | 2.8 ms | 2.8 ms | 35.5 KB | 1.00 |
| 3 s idle after each | — | 0 ms | 0 bytes (run 2 saw one screen of 1.6 KB, 52.9 KB and 35.6 KB in the three idle windows; cause not identified) | 0 |

- Fact (measured): server CPU per key in `*long*` is far above the in-process render cost (about 3 ms at 201 lines). Most of it is spent after the screen reaches the client, since the wall time to the screen is much smaller.
- Inference, unverified: the demo's digit highlighter starts a job per change, and its result re-renders the whole text node (`tests/support/digit-highlighter.ss`). Other likely costs are GC over the demo's much larger heap, the 10–18 MB allocated per render, and HTTP request logging.
- This gap was not attributed further. Treat it as an open measurement question, not as rendering cost.

## 6. Correctness hazards for memoization

- **H1. Line-id pins are lost under reused ancestors** (Fact (measured), `bench pin` → `bench/pin.txt`).
  - `pin-line-run!` runs only for nodes actually visited (`plugin.ss:187`). `render-view` replaces the pin table with this drawing's pins (`:496`). So a text node below a reused block loses its pin on the next redisplay.
  - The run: a code block's lines 1–7 were drawn; a redisplay reused its block; then a line was inserted at its start. Its ids came out `1…8` instead of `0…7`, so they did not follow the text. The control case, where the block was drawn on the previous redisplay, gave `0 1 2 … 8`.
  - So in multi-node buffers such as `*mixed*` the documented promise "a line's id stays with its text … through edits above it" (`plugin.ss:37-41`) does not hold.
  - Inference: the consequence is morphs that rewrite lines instead of moving them, and possible scroll-anchor jumps. In `*long*` the text node is the start node, which is always visited, so the pins survive.
- **H2. "Render only from the node" is unenforced.** Any renderer reading a setting other than `face-remapping`, another node, `selected-view`, the clock, git or process state, or another service gets stale output while the node's key is unchanged (Fact (code): the key has no slot for such reads). External state is safe today only if a plugin writes it into node attributes or children (Inference).
- **H3. Renderer identity is `eq?` on the registered procedure.**
  - Fact (code): `how`, `plugin.ss:186, 197`.
  - Inference: changes inside helpers a renderer calls (redefinition through Tuna's open functions or advice), or behaviour driven by data the renderer closes over, do not invalidate kept HTML.
- **H4. Parents embed their children's HTML.** This is correct only because ancestors are stamped and point is in every focus-path key. A descendant's line-id offset is not in the ancestors' keys (Fact (code)). It is consistent today only because the text node and its ancestors are re-rendered together after an edit.
- **H5. Global or over-broad keys:**
  - `keymap-generation` is global (Fact (code)).
  - Point invalidates the whole focus path and every line of the focused node (Fact (measured): C-f costs as much as a key in `*long*`).
  - A decoration layer replaced with equal content re-renders everything (Fact (measured)).
- **H6. Line HTML embeds the text revision and absolute positions** (`data-item="N.P.R"`, `contract.ss:823-835`).
  - Fact (measured): every edit changes every drawn line's markup, so a per-line memo keyed on line content would emit tokens from an older revision.
  - Inference: `token-item` and `relocate-position` resolve old-revision tokens through the journal (`contract.ss:837-855`), so reusing an old token is semantically valid until the journal horizon (1,000 changes; toy: 100) and wrong after it.
- **H7. Rendering has side effects** (Fact (code)):
  - `view-point` relocates and stores point (`contract.ss:1054-1062`);
  - `client-view-scroll-item` rewrites `top-item` (`:1174-1181`);
  - `view-client` creates client views (`:1134-1141`);
  - `children-items-kept` fills.

  Inference: a memo that skips whole views would skip these relocations. They are benign caches today, but the dependency is real.
- **H8. Multiple cursors and selections.** Only the primary point is in the key. ADR 6's selections and any region or overlay rendering have no slot yet (Fact (code)).
- **H9. Async results.** A job result that sets highlights re-renders the whole text node and every ancestor even if only one line's spans changed. Nothing tells the renderer which range changed (Fact (code) and Fact (measured)).
- **H10. Per-tab caches.** Mirrored tabs drawing the same run re-render the same nodes once per tab (Fact (measured): 2× calls). There is no correctness issue, but sharing would need the key to omit the tab while including the run (Inference).

## 7. Seams where a generic memoization mechanism would attach

All Inference, drawn from the facts above.
- None needs a kernel change. They sit in the renderer plugin, the buffers contract and the web transport (ADR 12).
- The owner's constraints hold for all of them: one fat morph per redisplay, layout in the browser, only what is in view drawn, per-tab measurements, and a replaceable text store.

1. **The node memo point: `render-node`** (`plugin.ss:183-212`) and its renderer call (`:205-206`) through `context-define-node-renderer!` (`contract.ss:631-638`).
   - Replace the fixed key `(revision, view-state, how, inputs)` with a dependency record captured while the renderer runs: the node revision, plus each other input read through tracked accessors (a setting, a node, a selection, an external source with its own revision), each as a (source, revision) pair.
   - This removes H2 and H3 by construction for reads that go through the accessors, and works for any node kind.
2. **The line memo point: the loop in `render-text-node`** (`:258-279`).
   - Key each line on: its content version (from the journal's changed-line ranges, §4), the spans intersecting it, the cursor column or selections on it, its id, and its token.
   - This needs tokens that do not embed the global chars revision (H6), or a token computed outside the memoized part.
   - It applies to any node opening into items, not only text (`drawn-children` already enumerates per item).
3. **The change source: the buffers contract journal** (`text-changes-since`, change records, `after-change-hook`). It is store-independent and already shared by the default and toy providers. `TextStore` needs nothing. Highlight layers need a changed-range or per-layer-revision API at `set-highlights!` (`contract.ss:518`).
4. **The pin store** (`view-html-pinned-ids`, `:99-102`, `:486-496`). Pins must be carried forward for unvisited text nodes, as kept HTML already is (fixes H1). A memo keyed on line ids depends on this.
5. **Splitting view state.** Point and selections should be per-line (or per-item) inputs of the focused node rather than a key on every focus-path ancestor, so C-f re-renders one or two lines and no ancestors (H5).
6. **Output assembly:** `html-string` per node and per screen (`:156-158`, `:202-209`, `:510`), and the transport's copies (`web/plugin.ss:169-190, 223, 632`; gerbil-datastar `split-lines`/`event-frame`).
   - Kept fragments are copied once per re-rendered ancestor, then four or five times per screen.
   - A chunk list or rope of fragments handed to the writer would make assembly cost the bytes once. Comparing with the previous screen could then use the fragments' identities instead of `string=?`.
7. **Cross-tab sharing:** `html-rendering.clients` (`:104`, `:498-503`). A memo table keyed on the full dependency record, not on the tab, would let mirrored tabs share node and line HTML (H10).
8. **Derived structure:** `children-items-of` (`contract.ss:703-721`). Updating it incrementally when one child changes would remove `*mixed*`'s 1.6 ms per edit. This is state-side memoization, separate from HTML.

## Contradictions

- ADR 13 ("Drawing"; "Stage 3 additions") says a part's HTML is reused when its revision, its view state and "the display-wide inputs (faces, settings)" are unchanged. The code captures only `face-remapping` and the keymap generation (`plugin.ss:462`); no other setting is in the key.
- The renderer header promises line ids that follow their text (`plugin.ss:37-41`). Measured (H1): this fails for text nodes below reused ancestors.
- Cost figures differ. ADR 15 and TODO.md give about 10–11 ms of server CPU and 25–36 KB per key screen in `*long*` at two screens. This audit measured:
  - 2.9 ms render, 53 KB, for an assumed 226 lines in-process;
  - 7–37 ms wall and 27–64 ms total server CPU per key over HTTP at 201 lines.

  The scopes differ (render only vs whole process; drawn counts measured by a browser vs set by hand). Not a code contradiction.

## Missing evidence

- The real drawn counts a browser produces in `*long*` and `*mixed*` at `drawn-screens` 2. These were assumed (90/135 and 30/45) or left at the pre-report 200/200.
- Attribution of the end-to-end server CPU beyond render (about 20–55 ms per key in `*long*`): GC over the full demo heap, the digit-highlighter jobs and logging were not separated.
- The source of the occasional idle screens in HTTP run 2.
- Browser-side morph cost per screen (not measured).
- Whether `context-define-node-renderer!` re-registration or `redefine` changes `how` in practice (H3 is reasoned, not tested).
- Gambit GC behaviour under the full demo; the in-process heap was small.

## Sources

**Kept (local, read in this run):**
- `agents/STATUS.md`, `TODO.md`, `agents/research/layout-state/README.md`, and ADRs 4, 6, 7, 12, 13, 15 and 16: the owner's decisions and earlier measurements.
- `plugins/renderer/{plugin,contract}.ss`, `plugins/layout/{plugin,contract}.ss`, `plugins/web/plugin.ss`, `plugins/buffers/{contract,plugin}.ss`, `plugins/buffers/tests/support/toy-buffers.ss`, `plugins/text-store/{contract,plugin}.ss`, `plugins/text-store/tests/support/string-text-store.ss`, `plugins/keys/{contract,plugin}.ss`, `tuna/kernel/loop.ss`, `plugins/{echo-area,minibuffer,help,buttons,completion-vertical}/plugin.ss`, `demo/{init,long-buffer,mixed,demo}.ss`, `tests/support/digit-highlighter.ss`.
- `.gerbil/pkg/git.cons.io/jay/gerbil-datastar/http/{api,private/core}.ss` and `.../gerbil-sse/sse.ss`: the wire format.
- Scratch evidence in `/home/jay/Code/workbench-gerbil/scratch/rendering-audit/`:
  - `bench/bench.ss`, `bench/build.sh`, `bench/run2.txt`–`run4.txt`, `bench/pin.txt`;
  - `http-client.py`, `run-http.sh`, `http-run1.txt`–`http-run3.txt`;
  - the built copy `tuna/` (`git archive` of `e972004`).

**Deprioritized:**
- `docs/overview.md`: not needed; the code was read directly.
- Web sources: not needed for a code audit.

## Next steps

1. Fix H1 (carry pins forward for unvisited text nodes) before any finer memo; it is a small, isolated change in the renderer plugin.
2. Measure real drawn counts and end-to-end CPU with a browser and the digit highlighter off (or its layer empty), to separate rendering from job and GC cost.
3. Prototype seam 2 (a per-line memo) in scratch. Prerequisites: a revision-free token, line-change ranges from `text-changes-since`, and the cursor as a per-line input. Then measure C-f and typing in `*long*`.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Report gives the full path with file:line citations (§1); the cache, its key and what one keystroke recomputes (§2); an input table with captured or not (§3); the change information and the TextStore limits (§4); in-process and HTTP measurements for *long*, *mixed* and idle, split into state, render and transport (§5); hazards with H1 reproduced (§6); memo seams (§7); summary table at the top; residual risks listed."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 timeout 900 env GERBIL_PATH=$PWD/.gerbil gerbil build (in scratch/rendering-audit/tuna, a git-archive copy of e972004)",
      "result": "passed",
      "summary": "Built an isolated copy; the repository was not touched"
    },
    {
      "command": "systemd-run ... timeout 900 ./bench (scratch/rendering-audit/bench)",
      "result": "passed",
      "summary": "In-process render, state and transport timings for *long* and *mixed*; output in run2-run4.txt"
    },
    {
      "command": "systemd-run ... timeout 300 ./bench pin",
      "result": "passed",
      "summary": "Reproduced hazard H1: line ids do not follow their text under reused ancestors"
    },
    {
      "command": "systemd-run ... timeout 900 ./run-http.sh (3 runs)",
      "result": "passed",
      "summary": "End-to-end wall time, server CPU and SSE bytes per key and idle; each tuna process was stopped by its exact PID"
    }
  ],
  "validationOutput": [
    "*long* 90/135 key: render 2.89 ms, 10.5 MB allocated, 53.5 KB frame, 226 lines; C-f the same",
    "*mixed* key: render 2.1 ms, of which node-item-count recount 1.6 ms; siblings reused",
    "idle redisplay: render 0.2-0.7 ms, identical screen, nothing sent",
    "HTTP *long* key: 7-37 ms wall to the screen, 27-64 ms server CPU per key, about 53 KB per screen"
  ],
  "residualRisks": [
    "Drawn counts were assumed (90/135, 30/45) or left at 200/200, not measured by a browser",
    "End-to-end server CPU beyond render is not attributed (GC, digit-highlighter jobs, logging)",
    "Line numbers cite e972004 and drift with later commits",
    "H3 (renderer identity under redefinition) is reasoned from code, not tested",
    "Another tuna on port 9450 (started 08:04, not by this run) was left running untouched"
  ],
  "noStagedFiles": true,
  "diffSummary": "No repository changes; the report was written to the configured artifact path only",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "Scratch artifacts are in /home/jay/Code/workbench-gerbil/scratch/rendering-audit/. Every Tuna process this run started (PIDs 2644663, 2647008, 2649996) was stopped. The owner-facing destination agents/research/rendering/tuna-render-audit.md was not written in the repository, as instructed."
}
```
