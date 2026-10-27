# Brief: a profiler that lives entirely outside the core

**Date:** 2026-10-12. **Status:** resumed 2026-10-27 (owner: the editor lags); plan [`agents/plans/profiler.md`](../../agents/plans/profiler.md). Since this brief: job started and finished come from hooks in the jobs library, not the kernel; redraw is memoized pieces; and each tab's tree runs to the browser having applied its screen, with the browser's own timings. Decided 2026-10-12: reports in a `*profile*` buffer (1a), sampling may use Gambit internals (2), built after the hooks-and-advice milestone (3). Measuring and reporting are two plugins: the profiler needs only hooks, advice and sampling; the report needs the buffers contract. Research: `agents/research/profiling/`.

## What we're building and why

A profiler plugin that answers "where did the time go?" for any key press, command, background job, or plugin, at any depth, not just "how long did the last key press take". It must be completely optional: Tuna's core and default plugins never mention it. They only offer general-purpose hooks that other plugins (macro recorders, loggers, status indicators) can use too. Turn the profiler off, or never install it, and nothing remains.

The earlier latency counter failed this test and has been removed (`380fdc0`). The Racket version of Tuna made the same mistake with its profiler; this design is built to avoid it.

## Prior art

- **Koyo** (your Racket web framework): `with-timing` blocks build a nested tree of timings per request, shown as a collapsible widget. It is cheap when disabled (one flag check). Its weakness: you have to wrap code by hand to see inside it.
- **Emacs `elp`:** instruments functions *by name* at runtime, through advice, without touching their source.
- **Emacs `profiler.el` and Gerbil's `gxprof`:** sample the call stack on a timer, showing hot spots anywhere, including code nobody instrumented, as a statistical call tree.

Each answers a different question, so the proposal combines all three.

## The picture

![Where the profiler gets its measurements](../diagrams/profiler.svg)

## How you'd use it, in four layers

1. **Automatic, no code changes.** With `M-x profiler-mode` on, every key press gets a tree built from general hooks:
   - when the key arrived;
   - the command it ran;
   - the hooks that ran;
   - the services called (the text store, the renderer), observed through advice on service methods;
   - the redraw;
   - when each browser received the screen;
   - any background job it started, plus memory allocated and garbage-collection time per step.
2. **By name, no code changes (like Emacs `elp`).** `M-x profile-function` or `M-x profile-plugin` instruments a function or a whole plugin while Tuna runs, using the same advice mechanism. It's undone cleanly by the plugin's receipt.
3. **By hand, only for detail inside one function (like Koyo).** `(with-span "parse imports" …)` adds a sub-step. If no profiler is installed it just runs the body, at the cost of a single check.
4. **Sampling, for everything else (like `profiler.el` and `gxprof`).** `M-x profiler-start` / `profiler-report` samples call stacks on a clock tick and shows the hottest code, including Tuna's own core, which can't be advised.

So ordinary code never needs profiling lines. You add `with-span` only when you want detail the other layers can't see.

## What a report could look like

One key press, typed while a slow highlighter plugin is on:

```text
key "7" arrived ........................................ 3.4 ms
├─ command self-insert-command ......................... 0.21 ms   1.2 KB
│  ├─ text-store replace (rope) ........................ 0.02 ms
│  └─ after-change-hook ................................ 0.05 ms
│     └─ slow-highlight → started job ................... 0.01 ms
├─ redraw ............................................... 0.40 ms   8.0 KB
│  └─ renderer render-screen (html) ..................... 0.35 ms
├─ screen delivered: tab 1 .............................. 2.6 ms
└─ screen delivered: tab 2 .............................. 2.7 ms
job highlight *scratch* (background) .................... 300.4 ms
```

It appears in a `*profile*` buffer, collapsible like Koyo's widget, keeping the last N key presses.

## What the rest of Tuna must offer (all general-purpose)

| Where | Offers | Other users of it |
|---|---|---|
| Kernel | One generic lifecycle-event hook: task started and finished, job started and finished, redraw started and finished | Debugging, a "busy" indicator, keyboard-macro recording |
| Key handling plugin | `pre-command-hook`, `post-command-hook` (already required by ADR 8; Emacs has them) | Countless Emacs packages |
| Browser connection plugin | "key arrived" and "screen delivered" hooks | Input logging and replay, sync indicators |
| Plugin runtime | Advice on service methods and package functions (already in ADR 1, not built yet) | Any package that adjusts another's behavior |

None of these mention profiling, and each is cheap when nothing listens.

## Decisions for you

1. **Where reports appear.**
   - (a) In a `*profile*` buffer, a collapsible tree. This is my recommendation: it's Tuna's own UI and exercises tree buffers.
   - (b) A small floating widget on every screen, as in Koyo.
   - (c) Both, with the widget as a later plugin.
2. **Sampling uses Gambit's internal (`##`) primitives,** the same ones `gxprof` uses (heartbeat interrupt and continuation capture). They're undocumented, so they could change between Gambit versions. I'd accept that inside this one optional plugin, with a test that fails loudly if they change.
3. **When to build it.** The generic hooks and advice are needed anyway (ADR 1 and ADR 8), so I'd build them in the next milestone and the profiler plugin right after, as the first real proof that something substantial can attach from outside. Alternatively it waits until after files and `M-x`.

## New terms

- **Span:** one timed step in the tree, such as "command self-insert-command".
- **Advice:** wrapping a function so code runs before, after, or around it, as in Emacs.
- **Sampling:** periodically noting what code is running, to see where time goes statistically.
