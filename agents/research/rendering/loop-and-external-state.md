# The editor loop, redisplay, and state from outside Tuna

Research, 2026-10-22, read-only. Tuna at `e972004`. Labels: **Fact** (read in code or a source, cited), **Inference** (my reasoning), **Proposal** (a design suggestion, not a decision). Line numbers refer to the files at the commits named.

## Summary

- **Keep the kernel exactly as it is.** It marks the screen dirty after every task, coalesces input, and redisplays when the queue is empty or after 100 ms. Emacs works the same way: it calls redisplay after every command, timer, and process read, and redisplay itself decides cheaply that nothing changed. The waste today is in the display side. The 2 s session-save timer makes every open tab render a full screen. The renderer then rebuilds the screen string, and the web plugin compares it with the previous one and sends nothing. Move the "could anything visible have changed?" test into contracts and the display provider. Each owner of renderable state (buffers, layout, settings, keys, stylesheets) exposes one **generation** number. The web plugin skips a tab when its generations and its client generation have not moved. A redisplay that changes nothing then costs a few integer comparisons. Also make session saving change-driven, so an idle editor wakes nothing.
- **State from outside Tuna arrives as a source.** Code off the baton reads the outside state as plain data. It compares that data with the previous reading, also off the baton. Only when the reading differs does it post a result. The result task then changes only the plugin-owned nodes that changed, which stamps their revisions. The ordinary redisplay re-renders only those nodes. When nothing changed, nothing is posted, so no task runs and no redisplay happens. This is Hyperlith's and Northstar's "tell connections to re-render, let them render from state", with the compare moved to the source. Three gaps exist today:
  - timers run a task on every tick;
  - the jobs library posts exactly one result per job, although ADR 3 says a job may post several;
  - `set-node-attribute!` stamps a revision even when the value is unchanged.
- **Several tabs:** key the renderer's HTML memo by content (node, revision, view state, inputs) per view instead of per client. Mirrored tabs then share almost every fragment, which is Anders's "render shared parts once per batch". Render a tab only when its page has applied its last screen, as Hyperlith does.
- **Acceptance demo:** a `proced`-style plugin reads `/proc` once a second in a streaming job and shows each process as a row node. Measure two things:
  - rows rendered equal rows changed;
  - with nothing changing, the editor runs zero tasks, zero redisplays and sends zero screens.

## 1. When and why redisplay happens today

### Facts

- **The loop marks dirty after every kind of task.** It does so for:
  - dispatching input or a queued task (`tuna/kernel/loop.ss:416,419`);
  - starting a job result (`:404`);
  - a task ending (`:465`);
  - a suspension (`:510`);
  - a resume (`:532`).

  `run-ready!` runs resumes first, then input (unless a redisplay is overdue), then results. It redisplays only when nothing else is ready (`:391–409`). `redisplay-cap` is 0.1 s (`:156,385–386`). This is ADR 3's "after a task completes or suspends, the loop marks the screen dirty… coalesces".
- **The Display provider is the web plugin.** `{redisplay! web-server}` renders a screen for every tab that has a stream open or wants one (`plugins/web/plugin.ss:195–205`). `publish-screens!` sends a tab its screen only if the string differs from the tab's last screen, if the tab is owed a screen for a scroll report, or if the stylesheets changed (`:215–229`). Its comment names the session save: "Timers such as the session save redisplay without changing what is shown" (`:212`). Commit `90fb132` ("web: send no screen when nothing on it changed") added this.
- **The session save timer** runs every 2 s (`plugins/session/plugin.ss:29,287–289`, `(unless (input-pending?) (save! self))`). `tuna/lib/timers.ss:46–51` calls `spawn-task!` on every tick, so each tick marks the screen dirty and redisplays.
- **Before `90fb132`**, the resource audit measured an idle tab receiving a full screen every 1.989 s: 2.36 % of a core and about 1.68 MB/s with a large text (`agents/research/resource-audit-2026-10-15.md:30,108`).
- **Opening a page or stream depends on "every task dirties".** `ask-redisplay!` sends `'redisplay` to a keeper thread, which spawns a no-op task `'tab-screen void` (`plugins/web/plugin.ss:563–577`).
- **The renderer memoizes per node, per client.** It reuses a node's HTML while these are unchanged: the node revision, the view state, how the node kind renders, and the display-wide inputs (face remapping, keymap generation) (`plugins/renderer/plugin.ss:54–63,186–212`). The memo is kept per client (`:16–19,498–510`). The screen root is always rebuilt: `render-layout` walks every view, and `html-string` serializes the whole `<main>` (`:498–510`). TODO.md records that a redraw with nothing changed costs about 2 ms on a 5,000-line text (`TODO.md:24`).
- **Every tab with a stream is rendered on every redisplay**, whether or not its page has applied the previous screen (`plugins/web/plugin.ss:200–201` filters on `wanted?` or `streams > 0`). Sending waits for `/applied` (`await-screen`, `:255–278`). Hyperlith instead skips rendering while the previous frame is undelivered: "Only render again if previous event was sent; this gives you back pressure and frame dropping" (`hyperlith/src/hyperlith/impl/datastar.clj:138–141`, `34dbe2e`).

**Inference.** Today's idle cost is one task plus one full render and string comparison per tab every 2 s. That is small in absolute terms but not zero: it grows with tabs and screen complexity, and it allocates. Under fast typing, a slow tab renders screens that the next redisplay replaces before they are sent. Neither cost has been re-measured since `90fb132` (missing evidence).

### How others decide when to redisplay

- **Emacs** (`/home/jay/Code/emacs` at `541f693`):
  - **When it runs.** The command loop redisplays whenever no input is pending (`src/keyboard.c:2704–2711`). It also redisplays after timers run (`detect_input_pending_run_timers`, `:12045–12055`), after reading process output (`src/process.c:5614–5615`), and after auto-save (`:2898–2904`). So Emacs too redisplays after nearly everything.
  - **How it skips work.** The savings come from change flags inside redisplay. `windows_or_buffers_changed` is 0 when only the selected window needs looking at. Otherwise per-buffer, per-window and per-frame `redisplay` bits select what to redo (`src/xdisp.c:725–754`). `pre-redisplay-function` and `pre-redisplay-functions` let packages update state just before a redisplay (`src/xdisp.c:14234–14250,39227`; `lisp/simple.el:7345–7352`; used by `hl-line` and `display-line-numbers`).
  - **The cost.** Missed flags show stale screens, hence `force-mode-line-update`. *(Inference from common Emacs practice; not re-verified here.)*
- **Hyperlith** (`/home/jay/Code/hyperlith` at `34dbe2e`):
  - **The batch loop.** The loop drains a transaction queue, runs `batch-fn`, then re-renders all connections on a thread pool and sleeps until the next tick (default 50 ms) (`src/hyperlith/core.clj:117–144,146–149`). In this version it re-renders every tick even when the batch was empty. Anders: "render every 100ms for all connected users, all the time regardless of events" (2025-11-04, data-verse/general, [link](https://discord.com/channels/1296224603642925098/1296225449260879973/1435259227752108052)). Later: "a new adaptive batching model. So no Xms throttle… Now its based on load" (2025-11-21, [link](https://discord.com/channels/1296224603642925098/1296225449260879973/1441535634480300093); code not public).
  - **New connections.** `billion_cells` triggers a batch on connect with a no-op transaction (`examples/billion_cells/src/app/main.clj:432–437`), the same trick as Tuna's `'tab-screen void`.
- **Northstar** (`/home/jay/Code/northstar` at `cb759ec`):
  - **Current code.** Each SSE handler subscribes to a NATS subject with a buffer of size 1. On any message it re-reads the database and patches `Main` (`web/features/counter/handlers.go:34–69`). Commands publish a content-free notification (`:72–90`).
  - **Older KV watch.** An older version watched a NATS KV key per session (`web/features/todo/service.go:84–85` at `387933c^`). Delaney: "NATS kv can be subscribed to so when an update happens you get the latest state and render then send all in like 3 lines" (2026-08-12, help/Open Stream on load, [link](https://discord.com/channels/1296224603642925098/1532246945949552801/1537093041800876052)).
- **Phoenix LiveView** ([assigns docs](https://hexdocs.pm/phoenix_live_view/assigns-eex.html), v1.2.13). Change tracking works per assign: "If `@title` is the same, nothing is executed and nothing is sent." External events reach a LiveView as `handle_info` messages, usually from `Phoenix.PubSub`, and update assigns. A clock example calls `:timer.send_interval` in `mount` ([LiveView docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)).
- **Elm** ([guide](https://guide.elm-lang.org/effects/time.html)). `subscriptions : Model -> Sub Msg`, for example `Time.every 1000 Tick`. Which sources are active is itself a function of state: the guide's exercise pauses the clock by turning the subscription off. *(Fact.)* The runtime diffs the subscriptions after each update. *(Inference; not fetched.)*

### Principled "redisplay only when something visible could have changed"

**Proposal.** Keep the kernel's conservative dirty-after-every-task rule. It is the execution rule (ADR 3), it matches Emacs, and it must stay correct for any plugin. Make a redisplay that changes nothing cost O(1) per tab. Use two levels, as Emacs does:

1. **A coarse flag (contracts).** Each owner of state the screen reads exposes a monotonically increasing **generation**, bumped by every change it makes:
   - buffers: any node stamp, any `client-view` write, any view change;
   - layout;
   - settings;
   - keys: `keymap-generation` already exists;
   - stylesheets (the registry already detects changes, `changed-stylesheets`).

   The display provider keeps, per tab, the vector of generations it last rendered from. If no generation has moved, it renders nothing for that tab: no walk and no string comparison. A generation is not shaped around one consumer: session save and autosave can use the same number to skip saving when nothing changed. *Do not* use `next-id!`, because tasks consume ids too (`tuna/kernel/tasks.ss:43`).
2. **Fine reuse (renderer, exists).** When a generation has moved, walk with the per-node memo as today. Most changes invalidate only one path.

**Rejected alternatives.**

- **Tasks declare "no display effect"** (a kernel flag on tasks or timers). This grows the kernel. A wrong declaration shows a stale screen, and saving a file *does* change visible state.
- **A fixed render tick** (Hyperlith 2025). Idle cost is a render per tick per tab, the opposite of the owner's goal on a laptop.
- **Dropping the dirty flag and scheduling from a hook.** This would move execution rules out of the kernel for no gain.

**Risk (Inference).** If anything the renderer reads lacks a generation, the screen goes stale: Emacs's `force-mode-line-update` bug class. The renderer's existing rule already confines what may be read ("a node renderer must draw only from its node, its children's renderings, and those inputs", `plugins/renderer/plugin.ss:61–63`). The generation set is exactly that list of inputs, so a test can check it. A wall clock in a status line would be its own source that bumps state, never something read at render time.

**Also:** make idle truly idle. Arm the session save as a one-shot timer when a generation moves, instead of a repeating 2 s timer (Emacs saves after `auto-save-interval` keystrokes or idle time, `src/keyboard.c:2895–2904`). Keep the `'tab-screen` wake-up. With the generation check, a forced redisplay for one new tab costs nothing for the other tabs. The new tab has no recorded generations, so it renders.

## 2. External and asynchronous state

### What the prior art does

| System | Trigger | Where it is compared | How it reaches the UI |
|---|---|---|---|
| Emacs process filter | output read in `wait_reading_process_output` | not compared | filter edits buffer → redisplay (`process.c:5614–5615`) |
| Emacs auto-revert | file notification when available (`auto-revert-use-notify` t), plus polling every 5 s unless `auto-revert-avoid-polling` (`lisp/autorevert.el:147,286,313`) | mtime/contents | revert buffer |
| Emacs proced | timer every 5 s (`proced.el:364`); updates a buffer only if its flag is set and, for `'visible`, only if the buffer is shown (`:962–974`) | none; it re-inserts every row | `erase-buffer` + reinsert |
| Magit | after Tuna-like git commands run (`magit-refresh`, `magit-mode.el:993–1023` at `2da34f1`) | none | `erase-buffer`, re-run inserters, restore point by section (`:1043–1088`) |
| Emacs jit-lock | display asks: `fontification-functions` for unfontified visible text (`lisp/jit-lock.el:269`), optionally deferred (`:135`) | — | faces then redisplay |
| Hyperlith | transactions drained in a batch | not compared; every connection re-renders | render all connections |
| Northstar | NATS publish / KV watch | not compared | handler re-reads and patches `Main` |
| LiveView | PubSub → `handle_info` | per assign (change tracking) | diff of dynamic parts |

Anders on the rule: "you can't morph/patch from outside the render loop in a view = f (state) style system" (2025-07-02, data-clojure, [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1390100461909971056)). Also: "You should broadcast that a connection should re-render and let it generate the html from its context" (2026-08-12, [link](https://discord.com/channels/1296224603642925098/1532246945949552801/1537056127932563488)). On push: "There's no polling… after you do a batch of updates/inserts you publish a refresh event and all connections re-run their queries" (2025-11-16, [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1439668823853629622)).

### Proposal: one shape for every source

1. **Trigger, off the baton:**
   - a period (polling);
   - an OS notification (inotify through a subprocess such as `inotifywait`; a native Gerbil binding is *unverified*);
   - a process reader thread (git, LSP); ADR 3 already coalesces each process's output into one pending, bounded message.
2. **Read into plain data, off the baton** (ADR 3/4: no live objects).
3. **Compare with the previous reading, off the baton.** The source thread keeps the last reading as plain data. Compare what is *shown*, not raw values: round CPU % to the displayed precision, format sizes. That avoids posts that would render identical HTML.
4. **Post only when different.** Keep one pending result per source key, latest wins: the same coalescing as job keys and process output. A burst of 1,000 file events becomes one post. Debounce bursty triggers (an editor's save, `git checkout`) with a short quiet period (about 50–200 ms; *Inference*, tune by measurement) before reading.
5. **Apply a minimal delta on the baton.** The plugin reconciles by stable key (pid, file path, section identity). It sets only changed attributes, and inserts and removes nodes. Only those nodes and their ancestors get new revisions. Node ids stay stable, so the renderer memo hits for every other node and Datastar/idiomorph match elements by id.
6. **Redisplay as usual.** The result task marks dirty, the buffers generation moves, and the renderer re-renders the changed nodes and the concatenation above them.

**Cost when nothing changed (Inference).** Push sources cost zero. A poll source costs one read per period on its own thread: no task, no wake-up of the editor loop, no render. Polling is acceptable for `/proc` and git status; prefer push wherever the OS or the tool offers it (LSP is push already).

**Visibility (Proposal).** As in proced's `'visible` and Elm's `subscriptions model`, a source should run only while something shows its buffer. Today no hook reports "buffer shown or hidden" (fact: the contracts define only `after-change`, `kill-buffer`, `buffer-list-update`, `client-gone`, `pre-command`, and `post-command`). Add a general layout-contract hook when the second consumer appears, Emacs's `window-buffer-change-functions` (*Unverified*). Several consumers would use it: proced-like lists, file watchers, LSP visible ranges, and highlighting priority. Until then, a source runs while its buffer is alive.

**Gaps to close (facts → proposals):**

- `tuna/lib/jobs.ss:148–163` runs `(run input cancelled?)` once and posts one result. ADR 3 says "A job may post several results" and names `target-alive` streams. **Proposal:** pass `run` a `post!` procedure so one long-lived job with `target-alive` validity can stream several results. Then a poll source is a job that loops: sleep, check `cancelled?`, read, compare, post. Plugin deactivation cancels it through its group. That is one mechanism instead of a new `sources` library. Extract a `tuna/lib/sources.ss` only if three users repeat the same loop.
- `tuna/lib/timers.ss:46–51` spawns a task on every tick. Polling through `context-run-with-timer!` therefore wakes the loop and redisplays every period. Poll inside the job instead.
- `plugins/buffers/plugin.ss:275–278`: `set-attribute!` stamps even when the value is unchanged. **Proposal:** the provider skips the stamp when the new value is `equal?` to the old one, so careless callers cost nothing. `set-children!` uses `memq` inside a loop (`:263–268`), which is quadratic in children. Fine for hundreds of rows; revisit for thousands.

**Per case (Proposal):**

- **Magit-like status.** Triggers are Tuna's own git commands (magit's model) plus a watcher on `.git/index`, `HEAD` and refs. Run `git status --porcelain=v2` in a job, parse it to plain data, and reconcile section and file nodes by key. This improves on magit's erase-and-reinsert (`magit-mode.el:1076–1079`): stable node ids keep point, folds and HTML reuse without magit's `goto-successor` repair.
- **Live process list.** See section 5. When every row's CPU changes every second, the cost scales with changed rows, which is honest. Sorting by CPU reorders rows every tick: still cheap on the server because unchanged rows reuse their HTML, but idiomorph has to move elements.
- **File watchers / auto-revert.** Notification first, polling as the fallback, as in Emacs. A visited text gets an exact edit or a reload as a result task.
- **LSP diagnostics.** These are push. Apply them as decorations with `rebase` validity. That bumps the text's decoration revision (ADR 4) and therefore the text node's revision. Today that re-renders the whole drawn run of the text node. Per-line or per-item reuse (`TODO.md:41`) is what makes only the affected lines recompute.
- **Async highlighting.** Emacs pulls fontification for the visible region at redisplay time (jit-lock). Tuna's equivalent keeps rendering pure: a highlighter job keyed per buffer prioritizes the drawn items that the clients measured (`client-view` drawn-before and drawn-after), then the rest; it is rebased, with ADR 3's inline fast path for small buffers. Per-line reuse matters here too.

## 3. Several tabs: sharing rendered fragments

**Facts.**

- ADR 16 renders one screen per tab from shared state plus that tab's measurements.
- The renderer keeps its memo per client (`plugins/renderer/plugin.ss:16–19,498–510`). So two mirrored tabs render every node twice, and `TODO.md:41` notes that a key's cost "is paid once per open tab".
- Anders: "This also opens up render sharing for shared widgets… you render that once every 100ms/every change and push the same render to all connected users" (2025-08-20, [link](https://discord.com/channels/1296224603642925098/1407452673866731652/1407773687771303966)). Also: "Game of Life had a shared view so it rendered once and cached for the render window" (2025-05-24, [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1375739437794725898)). Hyperlith README "Work sharing (caching)": "recalculate and cache values after a batch has been run" (`README.md:78–82`).

**Proposal.**

- **Key fragments by content.** Make the memo key (node id, revision, view state, how it renders, inputs) and hold the memo per *view*, not per client. Nodes inside an item have a view state that does not depend on any measurement (run `#f`, no focus state unless they hold point), so mirrored tabs share them exactly. Only these differ per tab: each view's spacers, scroll sizer, placement marker, the drawn-run boundaries, and the nodes that open into items. The second tab then costs roughly string concatenation.
- **Evict by reference.** An entry lives while some client's last drawing referenced it. This also fixes the audit's finding that removed nodes' HTML is retained (`resource-audit-2026-10-15.md:32`).
- **Render only for ready tabs** (Hyperlith back-pressure). At redisplay, render a tab only if its page has applied its last screen, it is owed one, or it is new. Otherwise mark it stale. When `/applied` arrives for a stale tab, `ask-redisplay!` runs. The generation check of section 1 makes that wake-up free for the other tabs.

## 4. Proposed loop and where each part lives

```
browser POST /commands ──► web: order by number ──► kernel input queue
                                                       │ Input.resolve!
external source thread/job ── read, compare ── post only if different ─┐
timer (one-shot, armed by change) ─────────────────────────────────────┤
                                                       ▼
kernel loop: resumes > input > results; each task mutates owned state
  (stamps node revisions, bumps its contract's generation); dirty after every task
                                                       │ queue empty, or 100 ms cap
                                                       ▼
Display.redisplay! (web): for each tab
  ready? (applied/owed/new) ── no ──► mark stale
  generations unchanged since tab's last render? ── yes ──► nothing
  else Renderer.render-screen(client): walk layout, reuse fragments keyed by
       (node, revision, view state, inputs), shared across tabs
  differs from last sent? ── no ──► nothing
  writer thread: one fat morph on the tab's SSE stream ──► page posts /applied
```

| Part | Layer | Change |
|---|---|---|
| Baton, queue, dirty after every task, 100 ms cap, `result-poster` | **Kernel** | none |
| Generation numbers (buffers incl. client views, layout, settings; keys and stylesheets already have one) | **Contracts** | add an accessor each |
| Stamp only on a real change | buffers **plugin** | small |
| Streaming jobs (`post!`) | jobs **library** | small; realizes ADR 3's wording |
| "Buffer shown or hidden" hook | layout **contract** | later, with its second consumer |
| Ready-gating, generation check per tab | web **plugin** | small |
| Content-keyed shared memo, per-line reuse | renderer **plugin** | medium |
| Change-driven session save | session **plugin** | small |
| Sources (proced, git, file watch, LSP) | their own **plugins** | — |

Everything stays immediate mode: the screen is still a function of state and is sent whole as one morph. The new pieces only decide whether computing that function again could produce anything new (*Inference*).

## 5. Acceptance demo: a live process list

**Plugin** `plugins/proced/` (Emacs `proced`; `list-processes` already names Emacs subprocesses):

- **Buffer and nodes.** Command `proced` opens `*Processes*`. The root is a `process-table` node with one `process-row` node per pid. A row's id stays fixed for its pid, and its attributes are pid, user, CPU % (one decimal), RSS (MiB), and command. Each node kind has its own renderer, and the plugin styles them in its own `tokens.css` and `rules.css`.
- **Source.** A streaming job (section 2) reads `/proc/[pid]/stat`, `statm` and `cmdline` once a second. It computes CPU % from tick deltas it keeps as job-local plain data, rounds what is shown, and diffs against the last rows. It posts `{changed: [(pid . fields)…], added, removed}` only when that delta is not empty.
- **Applying the delta.** The result task sets only the changed attributes and calls `set-node-children!` only for additions and removals. Rows are sorted by pid by default; sorting by CPU is a stress variant.
- **Fixtures.** A plugin option sets the `/proc` root, so tests use fixture directories.

**What to measure, and how.** Measurement lives outside the plugin (ADR 12): a test-support plugin that counts through advice or `task-started-hook`.

1. **Only changed rows recompute.** In a fixture, change one process's ticks. Expect exactly one `process-row` renderer call per tab with shared fragments, not one per tab per row. Expect one row stamped, and the screen bytes to differ from the previous screen only inside that row's element. Repeat with k changed rows and expect k renderer calls.
2. **Idle costs nothing.** With the fixture frozen and the buffer shown, run for 60 s. Expect:
   - 0 posts and 0 tasks (`task-started-hook` count);
   - 0 redisplays and 0 screens;
   - SSE bytes only from the 15 s heartbeats (`plugins/web/plugin.ss:84`);
   - server CPU from `/proc/self/stat` within 1–2 ticks of the baseline.

   Then hide the buffer (once the visibility hook exists) and expect 0 reads as well.
3. **Two tabs share work.** Open a second tab and repeat (1). Expect the renderer call count to stay the same and render time for the second tab to fall to concatenation cost.
4. **Typing is unaffected.** While all rows change every second (a real machine), type in another view. Compare keydown-to-`/applied` p50 and p95 latency with and without the plugin.
5. **Memory stays flat.** Churn 1,000 short-lived processes in the fixture. The number of kept HTML entries should stay equal to the drawn rows (no retention).
6. **Browser check.** Run it in a real browser, `.gerbil/bin/tuna --config demo/init.ss`, under the memory cap that AGENTS.md requires. Take a screenshot of the list updating, and stop the process by its PID.

**Pass criteria:** (1) and (3) hold exactly; (2) shows zero tasks and zero screens; (4) changes p95 by less than one frame (about 16 ms; *Inference*, owner to confirm).

## Contradictions

- **Rendering when nothing changed.**
  - Anders re-renders everyone on every tick regardless of events (2025-11-04; Hyperlith `core.clj:117–144` has no empty-batch check). He treats skipping unchanged frames by hash as optional and mainly about not leaking information. He argues it saves little with brotli, because unsent frames do not prime the compression window (2025-08-21, [link](https://discord.com/channels/1296224603642925098/1406980944069394454/1408013256852897866)).
  - The owner's goal and Tuna's `90fb132` skip unchanged screens.
  - Resolution: different constraints. A single-user editor on a laptop cares about idle power; a multi-user server cares about throughput. Tuna has no stream compression yet (roadmap item 8), so the brotli argument does not apply today.
- **Fine-grained notification.** Anders calls fine-grained pub/sub overhead (2026-03-24, [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1485952800327205005)). The proposal still broadcasts one "re-render" to every tab. The compare happens at the source, which is outside the render path, so it is not pub/sub per widget.
- **ADR 3 against the jobs library.** ADR 3 says a job may post several results; `tuna/lib/jobs.ss` posts exactly one.
- **A stale Hyperlith example.** `examples/game_of_life` calls `h/refresh-all!`, which no longer exists in `src/` at `34dbe2e`.
- **Northstar** today uses plain NATS subjects, not a KV watch. The KV watch is in older history (`387933c^`).

## Missing evidence

- Idle CPU and per-tab render time after `90fb132` were not re-measured.
- LiveView behaviour when `handle_info` changes no assign was not verified beyond the docs' per-expression statement. Elm's subscription diffing was not fetched.
- Anders's adaptive batching code is not public. Delaney said nothing found here about Tuna-like editor loops.
- No inotify binding for Gerbil was checked. The browser cost of reordering many rows was not measured.
- The 50–200 ms debounce figure and the 16 ms p95 budget are judgment calls, not measurements.

## Sources

- **Kept:**
  - Tuna `tuna/kernel/loop.ss`, `plugins/web/plugin.ss`, `plugins/renderer/plugin.ss`, `plugins/session/plugin.ss`, `tuna/lib/{timers,jobs}.ss`, `plugins/buffers/{contract,plugin}.ss`, ADRs 3, 4, 7, 12, 16, `agents/research/resource-audit-2026-10-15.md`, `agents/research/layout-state/README.md`, `TODO.md` (state of the code).
  - Emacs `541f693` (`xdisp.c`, `keyboard.c`, `process.c`, `simple.el`, `autorevert.el`, `proced.el`, `jit-lock.el`) and Magit `2da34f1` (prior-art mechanics).
  - Hyperlith `34dbe2e` (`core.clj`, `impl/datastar.clj`, README, examples) and Northstar `cb759ec` / `387933c^` (Datastar idioms in code).
  - The Datastar Discord local index (Anders and Delaney, linked above) and the LiveView and Elm docs (fetched 2026-10-22).
- **Deprioritized:** search-engine summaries (none used); Delaney's general fat-morph advice ("Fat morph until is a problem", 2026-05-03; "CQRS + fat morph in general simplifies everything to one pattern", 2026-03-13), which supports the model but says nothing about loop timing.

## Next steps

1. Re-measure idle and per-tab cost on `main` (the audit's method) to size the gains above.
2. Write a one-page brief for the owner covering generations, change-driven save, streaming jobs, ready-gating and the shared memo. Then build the proced demo as the acceptance test.
