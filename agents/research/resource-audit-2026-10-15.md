# Tuna resource audit — main, 2026-10-15

## Owner summary

- Main did **not** reproduce the runaway: all 39 Gerbil test files passed; the largest used 655 MiB, not gigabytes of runaway memory.
- An empty editor idled at **0.036% of one CPU core**, around 582–585 MiB of resident memory.
- The editor still sends an unchanged screen **every two seconds** while idle.
- With 50,000 text lines, that means about **1.68 MB/second** of needless screen traffic and **2.4% of a core**, doing nothing.
- A key in that large text cost **489 ms of server CPU and 3.35 MB sent**, versus **0.7 ms and 1.26 KB** in a tiny text.
- 10,180 mixed keys increased resident memory about **44 MiB**; another 10,000 cursor keys did not produce continued growth.
- **240 demo swaps plateaued** around 780 MiB; this audit found no swap runaway.
- Separate, garbage-collected probes confirmed retention of removed text nodes, removed-node HTML, and obsolete registration receipts.
- First fix the needless idle redraws; then address large-text rendering and the three proven retention paths. No source was changed.

## Scope, safety, and measurement definitions

**Fact:** measured checkout `/home/jay/Code/workbench-gerbil/tuna__resource-audit`, detached main commit `bcdf78fc0254c91e2685abc781bbb739413e13fd`. Toolchain: Gerbil `v0.19-dev-63-g1cfb032c`, Gambit `v4.9.8-19-gea114fc3`. Generated dependencies/build output stayed in this checkout; test data and isolated XDG directories stayed under `/tmp`. No source edits, commits, staging, remote operations, or changes to other checkouts. Final Git status and staged diff were empty.

Every build, test, Tuna, and `gxi` invocation ran inside a **4 GiB memory cgroup, zero swap, and a timeout**. Per-test and running-server monitors were configured to terminate only owned exact PIDs if sampled cgroup memory exceeded 3 GiB. No threshold fired, no timeout expired, and no out-of-memory kill occurred. Dependency setup peaked at 569.8 MiB RSS; the build peaked at 2,174.9 MiB RSS and took 257.98 seconds (`deps.log`, `build.log`). The build remained well below the cap. All three owned server PIDs were explicitly stopped; no audit server remains running.

RSS means resident set size: pages resident for a process, not live Scheme object size. MiB = 1,048,576 bytes; MB/KB are decimal. CPU percentages refer to **one core**, not the whole machine. `/proc/PID/stat` supplies user+system CPU time with 10 ms resolution (`CLK_TCK=100`). RSS and cgroup-accounted memory are different metrics and need not agree because shared pages are accounted differently.

**Fact** labels measured results; **Inference** labels source-based explanations. Fix sizes below are estimates, not approved designs or implementation work.

## Ranked findings

| Severity | What | Measured evidence | Likely cause / source | Suggested fix size |
|---|---|---|---|---|
| **High** | Each edit redraws and transmits the entire large text, including off-screen lines | 50,001 rendered line elements; 30 keys consumed 14.66 CPU seconds and 100,536,497 SSE bytes: **488.7 ms and 3,351,217 bytes/key** | **Inference:** `plugins/renderer/plugin.ss:123–150` walks all text lines; `:103–121` caches by whole node, invalidated by each edit/point change; `plugins/web/plugin.ss:89–99,215–226` publishes whole screens | **Large:** restrict rendering to visible content; finer-grained server-side reuse. Preserve whole-visible-screen transport rather than assume individual-node patches are needed |
| **High** | Unchanged idle state sends a full screen every ~2 seconds | Large text: 27 screens/52.03 s, 90,483,291 SSE bytes, 1.23 CPU seconds (**2.36% core**). Mean inter-screen interval 1.989 s. Zero heartbeat-only events | **Inference:** session save timer, `plugins/session/plugin.ss:29,284–286`; `tuna/lib/timers.ss:46–60` schedules tasks; `tuna/kernel/loop.ss:416–419,466–467` marks all tasks dirty, including unchanged saves | **Medium:** distinguish tasks with no display change, or suppress unchanged publication. Retain session saving and disconnect detection |
| **Medium** | A text retains every text node ever made for it | Probe replaced one child 1,001 times; **1,001 text nodes remained after detaching the final child and forcing GC** | **Fact/source:** strong `default-text.nodes`, `plugins/buffers/plugin.ss:37`; creation appends at `:245–246`; detach at `:249–253` clears parent links but not that list | **Small–medium:** prune attachment references or make the text-to-node backlink weak, with attachment/reuse tests |
| **Medium** | Renderer retains removed-node HTML while the same view/root stays visible | Same probe: **1,002 cache entries after final detach and GC**, for one empty parent tree | **Fact/source:** `view-html.nodes`, `plugins/renderer/plugin.ss:56–58,102–121`; whole-view pruning only at `:244–245`, root-change pruning at `:202–208` | **Small–medium:** evict removed-node entries during a render/revision change; prove surviving branches still reuse HTML |
| **Medium** | Replacing an entry or named hook does not replace its cleanup receipt | 1,001 repetitions of one entry and one hook: active counts **1 entry / 1 hook**, but **2,002 receipt closures survive GC** | **Fact/source:** `tuna/kernel/plugins.ss:97–99,122–124,176–177` appends inverse closures; `tuna/kernel/entries.ss:49–60` and `tuna/kernel/hooks.ss:57–75` replace active entries/callbacks without removing old inverses | **Medium:** retire replaced registrations' inverse receipts, without breaking deactivation. Relevant especially to the long-lived interactive/session owner |
| **Low** | Empty-editor memory is already substantial, and idle allocation is not literally flat | Initial browser-idle RSS 582.25 MiB; final 585.25 MiB after 302.07 s, **+3.00 MiB**; no high CPU | **Inference:** loaded runtime/configuration plus allocations from recurring save/render tasks. This audit did not isolate startup heap composition or prove an idle leak | **Investigate only:** heap/allocation profiling after eliminating unchanged-screen work |

## 1. Test suite, file by file

**Fact:** all **39/39** Gerbil invocations exited zero **and printed `HARNESS-OK`**. Checking the latter matters because this toolchain can exit zero despite failed checks. None exceeded **1 GB** RSS. Largest: `tuna/tests/integration/boot-test.ss`, **671,024 KiB = 655.3 MiB**. Largest sampled whole-cgroup usage: **619,671,552 bytes**. Sum of per-file wrapper durations: **106.32 s**; table wall times are `/usr/bin/time` command durations, which exclude some `systemd-run` setup overhead.

The relatively slow files were reload (~15 s), options (~14 s), boot (~9 s), and session (~7 s). They are flagged relative to the mostly sub-4-second files, not declared pathological. No file hit its 120-second timeout.

**Main's `tests/integration/session-evaluation-test.ss` passed in 4.54 s wrapper time, peak 351,504 KiB (343.3 MiB).** The reported review-cleanup runaway was not reproduced here; that other branch was not executed or modified.

Exact per-file commands and output are in `commands.txt`, `tests/NN.log`, `tests/NN.time`, and `tests-summary.json`.

| Test file | Wall (m:ss) | Peak RSS (MiB) | Harness |
|---|---:|---:|---|
| `plugins/commands/tests/integration/commands-test.ss` | 0:00.71 | 269.6 | OK |
| `plugins/completion/tests/unit/completion-engine-test.ss` | 0:00.60 | 247.0 | OK |
| `plugins/layout/tests/unit/tree-test.ss` | 0:00.93 | 307.4 | OK |
| `plugins/orderless/tests/unit/orderless-test.ss` | 0:00.59 | 244.0 | OK |
| `plugins/text-store/tests/unit/rope-test.ss` | 0:01.03 | 319.2 | OK |
| `plugins/web/tests/integration/web-test.ss` | 0:01.10 | 389.4 | OK |
| `tests/integration/basic-editing-test.ss` | 0:00.74 | 284.1 | OK |
| `tests/integration/buffers-contract-test.ss` | 0:01.82 | 446.5 | OK |
| `tests/integration/buffers-swap-test.ss` | 0:03.31 | 512.5 | OK |
| `tests/integration/buttons-test.ss` | 0:00.71 | 286.1 | OK |
| `tests/integration/command-loop-test.ss` | 0:00.82 | 277.2 | OK |
| `tests/integration/completion-test.ss` | 0:01.26 | 386.2 | OK |
| `tests/integration/configuration-lifecycle-test.ss` | 0:01.15 | 319.9 | OK |
| `tests/integration/editor-test.ss` | 0:03.10 | 319.8 | OK |
| `tests/integration/html-renderer-test.ss` | 0:01.02 | 337.2 | OK |
| `tests/integration/keys-test.ss` | 0:01.53 | 383.5 | OK |
| `tests/integration/layout-swap-test.ss` | 0:03.40 | 509.0 | OK |
| `tests/integration/layout-test.ss` | 0:01.11 | 351.5 | OK |
| `tests/integration/minibuffer-test.ss` | 0:00.92 | 321.1 | OK |
| `tests/integration/node-keymaps-test.ss` | 0:01.00 | 334.8 | OK |
| `tests/integration/optional-messages-test.ss` | 0:02.36 | 487.6 | OK |
| `tests/integration/options-test.ss` | 0:14.32 | 569.4 | OK |
| `tests/integration/prompt-foundations-test.ss` | 0:01.50 | 402.0 | OK |
| `tests/integration/reload-test.ss` | 0:15.00 | 499.1 | OK |
| `tests/integration/renderer-swap-test.ss` | 0:02.34 | 498.2 | OK |
| `tests/integration/session-evaluation-test.ss` | 0:04.33 | 343.3 | OK |
| `tests/integration/session-restart-test.ss` | 0:01.98 | 476.6 | OK |
| `tests/integration/session-test.ss` | 0:06.71 | 372.1 | OK |
| `tests/integration/settings-test.ss` | 0:00.64 | 249.6 | OK |
| `tests/integration/view-commands-test.ss` | 0:01.98 | 480.0 | OK |
| `tests/integration/web-test.ss` | 0:01.43 | 457.1 | OK |
| `tuna/tests/integration/boot-test.ss` | 0:09.11 | 655.3 | OK |
| `tuna/tests/integration/plugin-use-test.ss` | 0:03.68 | 363.6 | OK |
| `tuna/tests/unit/boundary-test.ss` | 0:02.92 | 373.8 | OK |
| `tuna/tests/unit/jobs-test.ss` | 0:01.14 | 270.1 | OK |
| `tuna/tests/unit/loop-test.ss` | 0:02.06 | 342.8 | OK |
| `tuna/tests/unit/plugins-test.ss` | 0:01.14 | 338.2 | OK |
| `tuna/tests/unit/timers-test.ss` | 0:00.82 | 245.4 | OK |
| `tuna/tests/unit/version-test.ss` | 0:00.51 | 213.6 | OK |

**Fact:** the additional frontend suite passed **12/12** checks (0.10 s, 60 MiB peak RSS); the demo configuration check passed (5.53 s, 618.0 MiB peak RSS). These are in `frontend-test.log` and `demo-check.log`. Individual suite logs can contain expected diagnostic messages after `OK`; success was taken from `HARNESS-OK`, not the final stderr line.

## 2. Five-minute browser-connected idle

**Method:** fresh starter configuration with temporary XDG config/state/cache/data/runtime directories, ephemeral port **42979**, one real `agent_browser` tab at the plain URL `http://127.0.0.1:42979/`. No keys/clicks during the measurement. Python read `/proc/3361162/stat` and the server cgroup every **2 seconds**, producing 152 samples over **302.073 seconds**. Browser screenshot: `starter-idle.png`. Browser memory/CPU are not included.

**Fact:**

- RSS: **596,224 → 599,296 KiB** (582.25 → 585.25 MiB); +3.00 MiB.
- Cgroup accounted memory: **550,084,608 → 553,136,128 bytes**.
- Server CPU: **11 ticks = 0.11 s**, average **0.0364% core**. Nonzero sampled intervals reached 0.5% at 2-second resolution; this is quantized CPU accounting, not a measured instantaneous spike.
- The initial idle window did not contain a large RSS fall. It establishes low CPU, not a proof of no long-term leak.

**Periodic work:** inspection names a 2-second session save task, including autosave callbacks, and a 15-second SSE (server-sent events) heartbeat (`plugins/web/plugin.ss:30–31,102–125,215–230`). Direct stream captures after the browser window proved that the 2-second task sends actual full screens, not heartbeat-only messages:

| Connected, no input | Duration | Screens incl. initial | Mean screen spacing | SSE bytes | Server CPU | RSS start → end |
|---|---:|---:|---:|---:|---:|---:|
| 9,711-character / 161-line scratch | 52.00 s | 27 | 1.996 s | 394,308 | 0.03 s | 629.30 → 636.80 MiB |
| 2,200,040-character / 50,001-line scratch | 52.03 s | 27 | 1.989 s | 90,483,291 | 1.23 s | 1,025.12 → 983.95 MiB |

Each stream capture had **zero `patch-signals` heartbeat events**. **Inference:** frequent full screens prevent the 15-second wait from reaching its heartbeat deadline. The large-text idle rate is approximately **1.68 MB/s** after excluding the initial screen; byte totals include SSE field framing but not HTTP/TCP headers. The large RSS fall is consistent with natural garbage collection/reclamation; it is not direct GC telemetry.

Raw data: `idle.csv`, `idle-stream-frames.json`, `large-idle-stream-frames.json`, matching summaries/samples, and `large-monitor.csv`.

## 3. Sustained keys, memory trend, and swaps

### Starter: real input protocol, 10,180 mixed keys

**Method:** after the untouched browser idle window, close the browser page and open one scripted `/screen` stream. Start input numbering at **1**. POST keydown objects matching `plugins/web/frontend/input-sender.ts` and the parser in `plugins/web/plugin.ss:277–299`. Every input includes all required boolean modifier/composition fields. Send a key, receive HTTP 204, and wait for a newer streamed screen before continuing. This exercises normal input dispatch, editing, layout, prompts, configuration reload, rendering, and transport; it does not call editing functions directly.

20 batches each sent **500 typing/RET keys**, then **C-/**, **C-x 3**, **C-x 0**, **M-x / C-g**, **C-c R**: 509 key events/batch, **10,180 total**. RET occurred every 60 typing events within a batch. Final autosave text was **9,711 bytes**, matching 111 starting characters + 10,000 typed characters/newlines − 400 characters undone. The final screenshot `starter-after-use.png` shows line 161. No malformed, duplicate, or skipped-input warnings appeared in server logs.

**Fact:** work was sent in **58.67 s**; with the final 60-second observation tail, server CPU increased **59.18 s**. RSS grew **587.88 → 631.96 MiB**, +44.09 MiB including the tail. Active-work endpoint was 631.09 MiB: **+4.32 MiB per 1,000 typing/RET keys** on this finite run, or +4.33 MiB/1,000 total mixed events including the tail. This is an observed endpoint slope, **not a leak coefficient**.

| Typing/RET keys | Total mixed keys | Elapsed work (s) | RSS (MiB) | Change per 1,000 typing keys (MiB) |
|---:|---:|---:|---:|---:|
| 1,000 | 1,018 | 5.21 | 616.77 | +28.89 |
| 2,000 | 2,036 | 10.56 | 614.85 | -1.92 |
| 3,000 | 3,054 | 16.33 | 616.85 | +2.00 |
| 4,000 | 4,072 | 21.88 | 620.63 | +3.78 |
| 5,000 | 5,090 | 27.60 | 620.90 | +0.27 |
| 6,000 | 6,108 | 34.33 | 622.48 | +1.59 |
| 7,000 | 7,126 | 38.55 | 627.58 | +5.10 |
| 8,000 | 8,144 | 44.99 | 629.77 | +2.18 |
| 9,000 | 9,162 | 51.67 | 623.21 | -6.55 |
| 10,000 | 10,180 | 58.67 | 631.09 | +7.87 |

**Inference:** growing text and undo history are legitimate retained state (`plugins/buffers/plugin.ss:31–33,111–116`); the change journal is bounded at 1,000 and periodically trimmed (`:40,87–95`). Render/configuration allocations add temporary heap pressure. RSS alone cannot apportion those costs. There is no clean monotonic per-key slope: the 9,000-key checkpoint is lower than the 8,000-key checkpoint.

### Fixed-content control: another 10,000 cursor keys

**Fact:** alternating **C-b / C-f**, 10,000 times total, kept the 9,711-character / 161-line text unchanged. Work took **28.52 s**, about **28.36 CPU seconds** including its six-second tail. RSS **633.59 → 629.17 MiB** (−4.41 MiB); maximum observed in per-key rows was **642.46 MiB**. Memory cycled rather than growing with every input. This finite fixed-state run supports a plateau, not a proof that every interaction is leak-free.

### Demo: 240 swaps

Fresh `demo/init.ss`, temporary XDG directories, port **46041**, with the same numbered POST/SSE path. Send **C-c w** then **C-c B**, 120 times each: **240 swaps / 480 key events**.

**Fact:** work took **99.70 s** and approximately **99.40 CPU seconds**; the 60-second tail brought total CPU to 99.65 s. RSS **764.31 → 779.69 MiB** including the tail (+15.38 MiB). By swap **120**, RSS was **779.56 MiB** and stayed at exactly that sampled value through swaps 140, 160, 180, 200, 220, and 240. The tail added only 0.125 MiB. **No continued swap-driven growth was observed.** This was the demo's small initial content, not a large-data swap stress test.

Artifacts: `sustained-*`, `motion-*`, `demo-*`, server journals, and `starter-session.ss`.

## 4. Per-key CPU and screen bytes

**Method:** same built executable and starter configuration. Each benchmark warms up with 10 `a` keys, snapshots server CPU ticks and SSE event count, sends a batch of `b` keys, then snapshots again. The small buffer started with the one browser-test character; the large buffer was seeded through the normal autosave/session restore path, not direct runtime mutation. Large input was **50,000 lines × 44 characters including newline = 2,200,000 ASCII bytes**, generated under `/tmp`; a final newline produces the 50,001st rendered line. No yank command exists in current basic editing.

| Buffer | Measured keys | Server CPU | CPU/key | SSE bytes total | SSE bytes/key | Batch wall |
|---|---:|---:|---:|---:|---:|---:|
| One line, 11 → 111 chars during measured batch | 100 | 0.07 s | **0.70 ms** | 125,662 | **1,256.6** | 0.108 s |
| 50,001 lines, 2,200,010 → 2,200,040 chars | 30 | 14.66 s | **488.67 ms** | 100,536,497 | **3,351,216.6** | 14.649 s |

**Fact:** exactly 100 and 30 full-screen events comprise those byte totals. Their contiguous spans are `small-frames.json[11:111]` and `large-frames.json[11:41]` (zero-based, stop-exclusive). Large screens contain **50,001 `class="line"` elements** even though a browser cannot display that many at once. The large buffer's initial screen alone was **3,351,192 bytes**. Both editing and cursor movement invalidate the focused text node's reuse key; this is not browser-visible-content-only work.

**Inference:** the ~698× CPU ratio and ~2,667× payload ratio show a buffer-size problem, not a constant-cost input problem. The small CPU result is only seven accounting ticks, so treat 0.70 ms as coarse. It is nevertheless nowhere near half a second. The text snapshot path allocates for reads (`plugins/buffers/contract.ss:284–288,311–344`, provider `plugins/buffers/plugin.ss:358–360`), but this audit did **not** separately profile its share of the measured 489 ms.

Large-run peak observed RSS including tail was **1,025.12 MiB**; cgroup peak observed was **1,017,888,768 bytes**. This was nowhere near the safety threshold. Subsequent idle collection reduced RSS to 983.95 MiB.

## 5. Retention probes and ownership inspection

**Method:** `tuna-audit-churn.ss` is a temporary measurement helper, not repository source. It imports this checkout's built plugins and existing fresh-kernel test helper. It creates one displayed parent node, repeatedly replaces its sole child with a new node showing the **same text**, renders, then records private container lengths using runtime slot inspection. It forces `(##gc)` at checkpoints and after detaching the last child. A separate fresh kernel repeatedly replaces a same-owner entry and named hook, also with forced GC. The running HTTP editor was **not** instrumented and no external forced GC was attempted there.

**Fact:**

| Probe checkpoint | Text's node references | Cached HTML entries | Cleanup receipts | Active entries | Active hooks |
|---|---:|---:|---:|---:|---:|
| 1 child / 1 entry+hook registration | 1 | 2 | 2 | 1 | 1 |
| 101 creations / registrations | 101 | 102 | 202 | 1 | 1 |
| 1,001 creations / registrations | 1,001 | 1,002 | 2,002 | 1 | 1 |
| Final child detached + GC | **1,001** | **1,002** | — | — | — |

The HTML count includes the persistent parent. Source proves there is no per-node prune while that view/root remains drawn. The receipt count is linear even though active replacement is correctly deduplicated. These are **retained-object counts, not measured retained-byte sizes**, and the probes do not claim these three paths explain the ordinary typing RSS increase. Four helper setup failures (import syntax, keyword calling convention, missing session provider, missing exported helper name) were corrected only in `/tmp` before the final successful run; they were not Tuna test failures. Final full output is `churn.log`.

Other structures inspected:

- **Web pending-input map:** `plugins/web/plugin.ss:254–272` removes each admitted sequence; if more than 64 wait behind a missing item it skips to the earliest received sequence. Stream opening clears the map (`:211–215`). **Inference:** it is bounded in normal/missing-sequence operation; no evidence makes it the cause of the measured growth. This audit did not separately inject missing/out-of-order sequences.
- **Job groups:** `tuna/lib/jobs.ss:86–98,176–184` cancels and clears groups on deactivation and removes idle key slots on completion. The demo exercised the highlighter/provider restarts; its plateau gives no evidence of a job-group leak here. This does not prove cooperative workers that never return cannot retain their inputs.
- **Session slots:** `plugins/session/plugin.ss:189–201,209–218,253–258` tracks live slots and removes them during cleanup; stored entries replace by slot name rather than accumulating each swap. Swap measurements plateaued. Dynamically creating infinitely many distinct slot names was not tested.
- **Hooks:** active named callbacks replace prior same-owner callbacks (`tuna/kernel/hooks.ss:57–75`), and normal plugin teardown removes them. The measured issue is **old inverse receipts**, not duplicate active hook execution. Receipts are cleared on deactivation (`tuna/kernel/plugins.ss:102–105`), explaining why fixed-provider swaps can plateau while a never-deactivated interactive owner can still accumulate receipts.
- **Global rebind invalidation:** every view uses global `keymap-generation` in its cache inputs (`plugins/renderer/plugin.ss:216–219`). **Inference only:** a rebind repaints unrelated views; no isolated rebind CPU/byte benchmark was run, so this known TODO is not presented as a newly quantified finding.

## Reproduction commands and raw data

All commands run from the detached checkout. `commands.txt` enumerates the exact successful measurement invocations, including every per-file test and each server's XDG environment and timeout. Files `tuna-audit-tests.py`, `tuna-audit-sample.py`, `tuna-audit-client.py`, and `tuna-audit-churn.ss` preserve the exact harnesses. Copies in this report directory are evidence; executed helper paths were under `/tmp`.

```sh
cd /home/jay/Code/workbench-gerbil/tuna__resource-audit
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 1800 /usr/bin/time -v make deps
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 1800 /usr/bin/time -v make
# Per-file loop: exact commands, logs, and time outputs are preserved.
python3 /tmp/tuna-audit-tests.py
# Temporary retention probe; imports this checkout, runs inside the cap.
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 120 /usr/bin/time -v gerbil env gxi /tmp/tuna-audit-churn.ss
# Sample one already-capped server (actual starter PID):
python3 /tmp/tuna-audit-sample.py 3361162 304 /home/jay/Code/workbench-gerbil/scratch/tuna-resource-audit/idle.csv
# Representative actual scripted key workload:
timeout 900 python3 /tmp/tuna-audit-client.py 42979 3361162 sustained sustained
```

The commands above are historical: server PIDs are stopped and must not be reused blindly. The Python clients did not launch Tuna; their target servers already had the cgroup and process timeout shown in `commands.txt`. Their own waits also had explicit client timeouts.

The large-buffer fixture was generated with Python:

```python
from pathlib import Path
p = Path('/tmp/tuna-audit-large')
for x in ['config', 'state/tuna/autosave', 'cache', 'data', 'runtime']:
    (p / x).mkdir(parents=True, exist_ok=True)
(p / 'state/tuna/autosave/%2Ascratch%2A').write_text(
    ''.join(f'audit line {i:05d} abcdefghijklmnopqrstuvwxyz\n' for i in range(50000)))
(p / 'state/tuna/session.ss').write_text(
    '(tuna-session 1 (buffers 1 (("*scratch*" 1 "%2Ascratch%2A" 51))))\n')
```

Browser commands were `open http://127.0.0.1:42979/`, screenshots to `starter-idle.png` and `starter-after-use.png`, one `press a` **after** the idle window, and `open about:blank` before scripted streams. The browser's first snapshot did not immediately show the `a`; its later insertion was verified in the small benchmark's final 111-character buffer. No browser tab ran alongside a scripted input stream.

### Limits and evidence caveats

- This is a finite, single-host run, not a proof of bounded memory for every workload. Tests initially overlapped starter startup/idle; no CPU isolation was imposed. Host/toolchain details are in `environment.txt` and `toolchain.txt`.
- Server CPU includes normal HTTP handling and stock logging. Browser parsing/morphing time, browser heap, wire headers, and compression were not measured. Large-buffer key latency in a real browser could be worse.
- A newer screen revision is not an input-sequence acknowledgment. Control-key/prefix/cancellation row timings can include an earlier intermediate screen; **do not attribute their individual rows to individual command CPU costs**. Final text, successful 204 responses, stream output, and completed observation tails establish whole-workload outcomes. Pure-character small/large batches have exact matching frame counts and byte spans above.
- In `small-summary.json` / `large-summary.json`, `screen_events` and `frames` count the whole connection, including warmup/idle tail; `keys`, `server_cpu_s`, `wall_s`, and `screen_bytes` refer to the measured key batch. Use the explicit event spans above to avoid mixing those scopes.
- RSS falls were observed, but there was no direct server GC instrumentation. Only the independent retention helper forced GC.
- The starter journal contains **nine HTTP handler error records** (four idle/closed-connection receive timeouts, four premature EOF records, one closed socket during shutdown); the client workload completed and there were no dropped-input warnings. These are recorded, not silently interpreted as memory leaks. The demo and large journals have no such error records.
- Only one Markdown report was written. All other deliverables here are raw measurements, harness copies, logs, or screenshots. No corrective code or design change was made.
