# Research: how real multithreaded editors handle concurrency, and what that says about Tuna's ADR 3

Labels: **Fact** = read in source/docs at the pinned commit; **Inference** = my reading; **Unverified** = not confirmed.
Read-only research. Nothing outside this directory was edited.

## Answer

**Tuna's design is sound and matches what Helix, Zed and Lapce do in practice.** All three keep one thread that owns the live document. Background work runs on an immutable snapshot, and its result is tagged with a revision. When the result comes back, the editor either discards it or adjusts it. None of them needs a CRDT (Conflict-free Replicated Data Type) or OT (Operational Transformation) for single-user editing. Zed's CRDT exists for collaboration only.

Top risks, in order:

1. **Rebase only handles "spans".** `rebase-spans` drops any span that an edit touched, including a long span with one character typed inside it. Zed and Helix map positions through edits and keep the result. Lapce keeps old styles while the new parse runs. Tuna's version will flicker, and it cannot yet carry results that are edits (format, rename, code action). Decide the result vocabulary before the second job kind lands.
2. **A job that is superseded or cancelled keeps running.** `job-cancel!` only marks the job; the thread runs to the end. Helix, Lapce and Zed all pass the worker a cancellation signal (generation counter, atomic revision, task handle). Without one, typing in a large buffer stacks up wasted CPU. This hurts more once the job is a real parser.
3. **No story for a result that arrives after the journal window.** The journal holds 1000 changes, so a result older than that is silently dropped. That is fine today. Once a slow server or a subprocess worker returns minutes later, there is no "re-run" step. Zed re-parses when the buffer moved on; Tuna's hook happens to restart the job on every change, which currently covers this by accident.

**CRDT/OT are not needed.** What would change that is more than one writer of the same text (collaboration, or an out-of-process plugin that edits text concurrently). See section 4.

## 1. Helix (commit `ba40e547426b0f9896c8bdc699a4ab11f2b37dbc`)

- **Threading. Fact:** `#[tokio::main]` (`helix-term/src/main.rs:25`) runs a multi-threaded async runtime. The editor and UI are one event loop. Background work comes back as callbacks sent through a channel (`helix-term/src/job.rs`: `Callback::Editor(Box<dyn FnOnce(&mut Editor)>)`) and run on the main loop with `&mut Editor`. Blocking work uses `tokio::task::spawn_blocking` (`document.rs:1094`).
- **Shared state. Fact:** `Document` has a plain `version: i32` field, bumped in `apply_impl` (`document.rs:1481`). It is mutated only through `&mut`, so the single owner is enforced by Rust, not by locks. Snapshots are cheap Rope clones, e.g. `diff_handle.update_document(self.text.clone(), false)` at `document.rs:1530`.
- **Syntax highlighting. Fact:** it is not a background job. On every transaction, `apply_impl` calls `syntax.update(old, new, changes, loader)` synchronously (`document.rs:1514`). tree-sitter parses incrementally under `PARSE_TIMEOUT` of 500 ms (`helix-core/src/syntax.rs:518`). If the parse fails or times out, syntax is turned off for that buffer. **Inference:** Helix relies on incremental parsing being fast, and does not need a background parse.
- **Diagnostics and code actions. Fact:** `handle_lsp_diagnostics` drops a `publishDiagnostics` whose `version` differs from `doc.version()` (`helix-view/src/handlers/lsp.rs:296-300`). Code actions capture `doc.version()` at request time and re-check it when applying (`commands/lsp.rs:751, 824, 870`). Formatting results are applied only if `doc.version() == doc_version` and are otherwise discarded with a log line (`commands.rs:3767+`). Workspace edits check `TextDocumentIdentifier.version` the same way (`helix-view/src/handlers/lsp.rs:119-122`). Diagnostics already stored are moved with the change set on every edit, with word-boundary rules and zero-width handling (`document.rs:1533-1565`).
  So Helix uses **exact-version discard for results that are edits, and position mapping for results that are decorations.** That is the same split as Tuna's `exact-revision` and `rebase`.
- **Cancellation. Fact:** `helix-event/src/cancel.rs` provides `TaskController`/`TaskHandle` with a generation counter. `cancelable_future` races a future against cancellation. Completion, pull diagnostics and signature help use it. Completion checks `handle.is_canceled()` before applying and logs "dropping outdated completion response" (`handlers/completion.rs:60`). Pull diagnostics use `doc.pull_diagnostic_controller.restart()` per request. Debouncing uses `AsyncHook` (`diagnostics.rs:120+`).

## 2. Zed (commit `26363aabdb31a0c016728634202e1ad5067033aa`)

- **Executors. Fact:** GPUI has `ForegroundExecutor` (main thread, `not_send: PhantomData<Rc<()>>`) and `BackgroundExecutor` (thread pool) in `crates/gpui/src/executor.rs`. `App` is not `Send`, so entities (buffers) are only reachable from the main thread ([glossary](https://zed.dev/docs/development/glossary)). Background tasks get snapshots and return values; applying happens with `this.update(cx, ...)` on the main thread.
- **Syntax (`Buffer::reparse`, `language/src/buffer.rs:1937-2012`). Fact:**
  1. Take a text snapshot and record `parsed_version`.
  2. Interpolate the existing syntax tree through edits since its last version (`syntax_map.interpolate`, which uses `anchored_edits_since`).
  3. If `may_block` and a `sync_parse_timeout` is set, try to parse synchronously within the timeout.
  4. Otherwise `background_spawn` the parse.
  5. On completion, **always install the result, even if stale**, then `parse_again = this.version.changed_since(&parsed_version)`. If the buffer moved on, call `reparse` again.
  Zed does not discard the stale tree. It installs it, because the interpolated tree is a usable approximation, and re-runs.
  The same pattern ("try synchronously within a time budget, else async") appears in autoindent (`request_autoindent` with `block_budget`, `buffer.rs:2089+`). **Inference:** this keeps the common fast case free of a one-frame lag.
- **LSP results. Fact:** `LspStore` keeps, per buffer and per server, the text snapshots it sent, keyed by LSP version, and retains the last 10 (`buffer_snapshot_for_lsp_version`, `lsp_store.rs:3443-3480`). A server response carrying version N is resolved against the snapshot for N, and its ranges become anchors (`lsp_store.rs:3019`). **Inference:** that response is then valid on the current text without any rebase step. This is the "anchor" answer to the problem Tuna solves with a change journal.
- **Anchors and CRDT. Fact:** an `Anchor` is `(insertion timestamp, offset in that insertion, bias, buffer_id)` (`text/src/anchor.rs`). The buffer is a CRDT, with a `Lamport` clock, a `clock::Global` version vector and operation queues (`text/src/text.rs:59-68, 113-124`). Resolving an anchor finds the fragment of the insertion it names; deleted text is kept as tombstones ([Zed's CRDT post](http://zed.dev/blog/crdts): "Fragments with tombstones are hidden… but they can still be used to resolve logical anchors"). `update_diagnostics` in `buffer.rs:2055` ticks a Lamport clock and sends an `Operation` for collaborators.
- **What works without the CRDT. Inference (strong):**
  - Snapshots plus versions (the rope is a persistent SumTree; Zed's [rope post](https://zed.dev/blog/zed-decoded-rope-sumtree) says snapshots can be read from several threads).
  - Foreground ownership with background compute.
  - Keep the snapshot that was sent to a server, and map its results forward.
  - Interpolate-then-reparse for syntax.
  - A sync-with-budget fast path.
  - A "buffer version changed since" check to schedule a re-run.
  What needs the CRDT: merging concurrent edits from several replicas, per-user undo, and anchors that survive deletion by identity (the tombstones). **Inference:** a single-user editor can get stable positions more cheaply from a change journal (Tuna, Helix) or by mapping through a changeset (Helix, Lapce).

## 3. Lapce (commit `f66ffaa95387794205c35864517de70958b9ea8d`) and Xi, Neovim, VS Code

**Lapce and Xi. Fact (README line 24, `Cargo.toml:73`, `lapce-core/Cargo.toml:21`):** Lapce says it is "designed with Rope Science from the Xi-Editor" and depends on `lapce-xi-rope` 0.3.2 (a fork of the `xi-rope` crate: rope, deltas, intervals, spans). **Inference:** that is where `apply_shape(delta)` comes from. **It does not use Xi's architecture.** Xi was a core process that owned the buffer, with the front end and plugins as RPC clients. Lapce's UI (Floem) owns the document and reads it directly. A separate `lapce-proxy` process (local or remote) runs file I/O, LSP, the terminal and WASI plugins, speaking JSON messages over stdio (`lapce-rpc/src/stdio.rs`). **The proxy holds a replica:** the UI sends `Update { path, delta, rev }`, and the proxy applies it only if `self.rev + 1 == rev` (`lapce-proxy/src/buffer.rs:119-124`, `dispatch.rs:168-179`), then forwards `didChange` to servers. Why Lapce left Xi's design is **Unverified**: I found no Lapce statement. Xi's own retrospective is in the capability audit.

**Lapce threads. Fact (`lapce-app/src/doc.rs`):**
- Every background result is delivered back to the UI thread through `create_ext_action`.
- Syntax parse: `trigger_syntax_change` records `rev` and a text (rope) clone, sets the old parse's `cancel_flag`, installs a new one, then `rayon::spawn`s `syntax.parse(...)` (lines 836-860). tree-sitter's `set_cancellation_flag` makes the old parse stop. The result is applied only `if buffer.rev() == rev` (line 842). Meanwhile `update_styles` has already moved existing highlight spans through the delta (`styles.apply_shape(delta)`, line 872+), so colours stay in place until the new parse lands.
- LSP results (format on save, document symbols, inlay hints, semantic tokens): captured `rev`, dropped if `doc.rev() != rev` (lines 786, 986, 1032, 1083).
- Semantic tokens use a shared `atomic_rev` (an `Arc<AtomicU64>`). A worker thread polls it and abandons work when the buffer has moved (lines 931-960). The same is used for diffs (1428+).
- Find results and inlay hints/diagnostics are shifted with the delta on each edit (`update_find_result`, `update_inlay_hints`, `update_diagnostics`).

So Lapce = **exact-rev discard + shifted old decorations + cancellation by shared revision counter**. No CRDT: edits are ordered deltas with a revision counter.

**Xi plugin async (only what was missing). Fact ([plugin docs](https://xi-editor.io/docs/plugin.html)):** in the "normal" mode a plugin works on a read-only snapshot and the core merges returned deltas with later edits. The doc says a syntax highlighter converges because it edits annotations while the user edits text. It also says "I plan to address… parallel edits head-on, using some form of operational transforms". **Inference:** Xi's plugin merging is Tuna's `rebase` where results are non-text; the part Xi paid for was plugins that return *text* edits.

**Neovim (`e7cd0e4375a48d32eea6776d6d26e92eed9fedbe`). Fact:** the main loop is single-threaded. Tree-sitter's async parse (`languagetree.lua:556-600`) runs in time slices of 3 ms (`default_parse_timeout_ns`), compares `changedtick` every step, and restarts the parse if the buffer changed. LSP edits are ignored if `buf_versions[bufnr] > text_document.version` (`lsp/util.lua:416`). **Unverified in this pass:** libuv job details and `vim.uv.new_thread`, which I recall cannot touch editor state.

**VS Code. Fact (LSP spec 3.17):** servers can reply `ContentModified` (-32801) when state changes during a request, and clients "should not show it in the UI… can resend the request". Extension host as a separate process and `TextDocument.version` are **Unverified here** (not read); I recall them but did not check.

## 4. Synthesis for Tuna

| Pattern | Helix | Zed | Lapce | Neovim | Tuna (ADR 3/4) |
|---|---|---|---|---|---|
| One owner of live document | Yes (`&mut Editor` on main loop) | Yes (foreground executor, `!Send`) | Yes (UI thread) | Yes | Yes (baton) |
| Immutable snapshot for workers | Rope clone | Rope snapshot | Rope clone | Buffer copy or tick checks | Persistent rope snapshot |
| Revision tag on every job | `doc.version` | `version`/`clock::Global`, LSP version snapshots | `rev` | `changedtick`, `buf_versions` | `revision` |
| Edit-like results | Exact version, else drop | Anchors against the sent snapshot | Exact rev, else drop | Exact version, else drop | `exact-revision`: matches |
| Decoration results | Map through changeset | Anchors / interpolate then reparse | Shift old, install if rev matches | Re-parse | `rebase-spans`: matches in spirit, coarser |
| Stale result installed anyway | No | Yes (syntax), then reparse | No | No | No |
| Cancellation | Generation counter / handle | Task drop | `cancel_flag`, `atomic_rev` | Tick check between slices | Mark only; thread continues |
| Time-budgeted sync path | Parse inline with 500 ms timeout | Sync parse with timeout, else background | No | 3 ms slices | None |
| Stable positions | Changeset mapping | Anchors (CRDT-based) | Delta shifting | Extmarks | Journal of change records |
| CRDT/OT | No | Yes (collaboration only) | No | No | No |

**Tuna already matches:** single owner; immutable snapshots; per-job revision; separate policies for edit-like and decoration-like results; dropping failed jobs; the "newest pending job replaces the old" key rule (Helix debouncing, Lapce cancel-and-restart); deferring to the loop with a single post.

**Gaps and corner risks:**
1. *Cancellation is not cooperative* (risk 2 above). Fix: give `run` an optional cancel token (an atomic flag, or the target's revision). That stays plain data, so it works for threads and subprocesses.
2. *Rebase vocabulary* (risk 1). Dropped spans vs mapped spans: map them (Helix and Lapce both keep and move highlights). Edits as results need an explicit policy (exact-revision, plus Zed-style "keep the snapshot, map forward").
3. *Job results are applied one at a time through the loop. Lapce, Helix and Zed all run follow-up work after applying.* Tuna's hook restart covers this today; make it explicit before a job that re-runs on its own.
4. *Sync fast path* (Zed, Helix, Neovim) is missing. For small buffers a 2 ms inline parse avoids a visible frame of mis-coloured text. This is a plugin policy, not a kernel feature.
5. *Slow results and journal window* (risk 3): `text-changes-since` returns `#f` past 1000 changes. Document that "dropped" means "re-run", and consider keeping the sent snapshot (Zed keeps ten).
6. *Subprocess workers* (Lapce proxy shows the shape): a replica needs ordered deltas with a `rev` check (`rev + 1`). If Tuna ever adds out-of-process workers or plugins, copy that rule rather than inventing one.

**Things Tuna does that none of them do (flag as risk):**
- The **suspendable task**: any code can wait at a yield point and give up the baton, and must re-read state afterwards. Helix, Zed and Lapce have no such thing; their commands are plain function calls. It buys Emacs-style direct code, and it means any task can see the document change under it. This is Emacs's recursive-edit hazard and should be tested with an edit-between-yield-points case.
- **`thread-interrupt!` as forced quit.** Zed and Helix cancel cooperatively (future drop, token). Gerbil's own standard-library maintainers avoid interrupt-injection (`src/std/AGENTS.md`, per the ADR). It is a last resort in Tuna, which is the right place for it.

**CRDT/OT verdict. Confirmed, not needed, for single-user editing with one writer.** Helix and Lapce are both single-user and use nothing but version numbers plus changesets. Zed's CRDT is explained by its authors as being for collaboration ([post](http://zed.dev/blog/crdts)). **What would change it:** (a) real-time collaboration; (b) background workers that *edit text* concurrently and must merge with typing (Xi's problem). (b) is avoidable by letting workers return edits as exact-revision results only.

## 5. Does Tuna break if threads become truly parallel?

(SMP build status in one line: installed `/opt/gerbil` and the branch's Gambit (`ea114fc3`, `config.log`) were configured without `--enable-smp`, `(gerbil-runtime-smp?)` is `#f`, and Gambit's `lib/_thread.scm` has a `cond-expand enable-smp` branch.)

I read `jobs.ss`, `loop.ss` (`new-task`, `spawn-task!`, `result-poster`), `ids.ss`, `timers.ss`, `hooks.ss`, `buffers.ss` snapshots and the rope/string stores. **Inference: nothing assumes single-core.** Specifics:

- **Off-baton entry points are all mailbox-based or locked.** Jobs post with `thread-send` to the loop (`result-poster`). `spawn-task!` and `cancel-task!` use `send-to-loop!`. `next-id!` takes a mutex. Hook lists use a mutex. Web admission and screen use mutexes (`web.ss`).
- **Job state (`state`, `slot.running`, `slot.pending`) is mutated only on the baton.** A job thread reads only its own captured `run` and `input`.
- **Snapshots are safe.** A snapshot is `(store, version, revision)`, and versions are immutable (string store copies; the rope caches counts at build time).
- **Revision counters are baton-only** and unlocked on purpose (`ids.ss`).
- **Remaining risks, all small:**
  - **Convention, not enforcement, keeps jobs on plain data.** A `run` closure that captures a live text, hash table or class instance would race. Today green-thread preemption already makes this unsafe; SMP makes it crash-prone (hash-table resize, MOP paths ADR 3 says are not SMP-safe). Add a debug check that a job input contains no live editor objects, or at least a lint.
  - **`new-task` runs on the job thread** (inside `post`), so it allocates a `defclass` instance and calls `next-id!` off-baton. It is lock-protected for the id, but class instantiation on a non-main thread is the MOP path to verify under SMP. Easy fix: post a plain closure and construct the task on the loop thread.
  - **The timer thread reads `t.name` and calls `spawn-task!` off-baton** while the baton sets `t.thread` after spawn. It reads only immutable fields, so this is fine, but it is the same pattern to watch.
  - **Cancellation by flag will need atomics** under SMP, and Gambit has no atomic-flag primitive that I verified. A mailbox message or a mutex-guarded box works.

## Recommendations (ranked)

1. **Add cooperative cancellation to jobs** — *change now*. Pass the job a cancel token; keep `job-cancel!` as the setter. Do this before the second real job, not after.
2. **Map spans instead of dropping them when an edit lands inside** — *change now* (small, in `rebase-spans`). Define what a span does when an edit lands inside it, as Helix and Lapce do.
3. **Decide the "result is an edit" policy** (format, rename, code action) — *decide before the first LSP milestone*. Recommended: exact-revision, applied as one undo group, dropped if stale (what Helix does), with optional snapshot retention (Zed).
4. **Construct the result task on the loop thread, not the job thread** — *change now* (one line of design, avoids the SMP MOP question).
5. **Document "stale result = re-run" and keep the "newest pending replaces the old" rule** — *no action*, state it in ADR 3.
6. **Time-budgeted inline fast path for cheap jobs** — *decide before the syntax-highlighting milestone*.
7. **Subprocess workers use ordered deltas with a `rev` check (Lapce proxy)** — *decide before any out-of-process work*.
8. **No CRDT/OT** — *no action*. Revisit only for collaboration or text-editing background workers.
9. **Test an edit between a task's yield points** — *decide before the minibuffer/completion milestone*. It is Tuna's one novel hazard.

## Shallow areas

- Helix: I did not read the tree-sitter layer in `tree-house`, nor Helix's `Transaction` composition and history.
- Zed: I read `reparse`, anchors, and LSP version snapshots, not `DiagnosticSet` construction, search, or project-wide result application. The diagnostic anchor path is an inference from the snapshot lookup call sites.
- Lapce: parse reuse of the old tree (incremental) is not confirmed; plugin (WASI) threading was not read.
- Neovim extmarks and VS Code: not read; marked above.

## Sources

Pinned commits: Helix `ba40e547426b0f9896c8bdc699a4ab11f2b37dbc`; Zed `26363aabdb31a0c016728634202e1ad5067033aa`; Lapce `f66ffaa95387794205c35864517de70958b9ea8d`; Neovim `e7cd0e4375a48d32eea6776d6d26e92eed9fedbe`; Gerbil branch `v0.19-staging` `1c6c15385979f0092574fbc2b828f3fb656319b3` with Gambit `ea114fc3d2f120abbe20393c1f9aeafdd3f8c89f`; Tuna `4411328f8e0263aea8820a17eeba43e05c190572`.

- Helix: https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/ — `helix-view/src/document.rs`, `helix-view/src/handlers/lsp.rs`, `helix-term/src/job.rs`, `helix-term/src/commands.rs`, `helix-term/src/commands/lsp.rs`, `helix-term/src/handlers/{completion,diagnostics}.rs`, `helix-event/src/cancel.rs`, `helix-core/src/syntax.rs`, `helix-term/src/main.rs`
- Zed: https://github.com/zed-industries/zed/blob/26363aabdb31a0c016728634202e1ad5067033aa/ — `crates/language/src/buffer.rs`, `crates/language/src/syntax_map.rs`, `crates/text/src/{text,anchor}.rs`, `crates/gpui/src/executor.rs`, `crates/project/src/lsp_store.rs`; https://zed.dev/blog/crdts ; https://zed.dev/blog/zed-decoded-rope-sumtree ; https://zed.dev/docs/development/glossary
- Lapce: https://github.com/lapce/lapce/blob/f66ffaa95387794205c35864517de70958b9ea8d/ — `README.md`, `Cargo.toml`, `lapce-app/src/doc.rs`, `lapce-core/src/syntax/mod.rs`, `lapce-proxy/src/{dispatch,buffer}.rs`, `lapce-rpc/src/stdio.rs`
- Xi: https://xi-editor.io/docs/plugin.html ; retrospective https://raphlinus.github.io/xi/2020/06/27/xi-retrospective.html (via the repo's capability audit)
- Neovim: https://github.com/neovim/neovim/blob/e7cd0e4375a48d32eea6776d6d26e92eed9fedbe/runtime/lua/vim/treesitter/languagetree.lua ; `.../lsp/util.lua`
- LSP 3.17: https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/specification.md (`ContentModified`)
- Tuna: `agents/adr/0003,0004,0006`, `tuna/lib/jobs.ss`, `tuna/kernel/{loop,ids,hooks}.ss`, `tuna/lib/timers.ss`, `tuna/services/buffers.ss`, `tuna/plugins/demo.ss`
- Gerbil/Gambit: `/home/jay/Code/workbench-gerbil/gerbil/src/gambit/{config.log,lib/_thread.scm,configure.ac}`; `/opt/gerbil/current` (`gxi` reports Gerbil `v0.19-dev-63-g1cfb032c`, Gambit `v4.9.8-19-gea114fc3`)
