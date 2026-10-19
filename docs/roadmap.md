# Roadmap

Each milestone is a working program that can be shown in the browser. Write a short plan (one page or less) when a milestone starts; record hard-to-reverse choices as ADRs.

## Done: architecture skeleton (2026-10-12)

Brief: [briefs/2026-10-architecture-skeleton.md](briefs/2026-10-architecture-skeleton.md). Goal: prove every seam in [the ADRs](../agents/adr/README.md) with the least feature code:

- the editor loop accepts browser keys, runs commands under the baton, and redisplays to every connected tab;
- the browser opens a plain loopback URL, protected by Host/Origin checks; input is sent immediately and ordered by page-load numbers on the server;
- a scratch buffer is one text node backed by the default persistent `TextStore`, shown through a view; positions are 1-based; typing, deleting, and basic motion work;
- basic editing is a plugin: deactivating it removes its commands and keys, and reactivating restores them; two plugins binding the same key survive either deactivation order;
- `C-g` interrupts a deliberately endless command;
- a `with-settings` binding is visible only to the command that made it, even while another command waits at a prompt;
- the kernel (plugin runtime, execution rules, shared vocabulary) is separate from every default plugin, and defaults use only public contracts;
- a second `TextStore` implementation, a second renderer, and a second (single-window) window manager can each replace the default; `describe-services` shows who fills each slot;
- a command prompts in direct style through a minimal minibuffer and resumes with the answer;
- a deliberately slow fake highlighter runs as a job: edits render first, and its decorations arrive later, shifted past any typing that happened meanwhile;
- a session slot and autosave survive a restart;
- keydown-to-patched-screen latency is measured (about 3–4 ms; the in-app instrumentation was later removed because it leaked into the kernel, and measurement moves to a separate profiler plugin).

Out of scope: windows and splits, files, modes, completion UI, real highlighting.

## Done: configuration (2026-10-13)

Brief: [briefs/2026-10-configuration.md](briefs/2026-10-configuration.md). Tuna starts from your own `init.ss`, which declares the plugins to turn on (`use-plugin`) with their options; `tuna init` copies the starter configuration, `tuna check` validates a configuration, and `reload-config` (`C-c R` in the starter) or `tuna reload` reloads it while Tuna runs, changing only what changed.

## Done: getting the core back to its intended shape (2026-10-16)

The skeleton let pieces of features creep into the kernel. The approved plan ([kernel contract](briefs/2026-10-kernel-contract.md)) fixes that first, in this order:

1. *Done (2026-10-12).* Clean up the kernel to match the contract (no new features). See [how Tuna works](overview.md#a-small-kernel-and-a-lot-of-plugins).
2. *Done (2026-10-13).* Buffers, views and layout: buffers really replaceable, views in a layout with splits and tabs, movable frames and frame marks, and the minibuffer and echo area as ordinary views ([brief](briefs/2026-10-buffers-views-layout.md), approved 2026-10-13). This brings forward the window part of the "Windows" item under "Later", except scrolling strips.
3. *Done (2026-10-13).* Take the demo out of the default startup: the starter configuration declares only real plugins, and the demo runs with `--config demo/init.ss`.
4. General-purpose hooks and advice, including redefining functions while Tuna runs (a brief first). *Partly done (2026-10-14, kernel cleanup with Cordis):* hooks with ownership and depth, and live redefinition; advice is not built. *Done (2026-10-16):* [brief](briefs/2026-10-hooks-and-advice.md): open package functions, `redefine`, function and command advice, `describe-advice`, the hook fixes, and the hungry-delete demo. Service-operation advice moves to the profiler ("Later").

## Done: HTML and stylesheets (2026-10-17)

Brief: [briefs/2026-10-stylesheets.md](briefs/2026-10-stylesheets.md). HTML is Tuna's only presentation language. Each plugin styles its own HTML with its own stylesheets on top of shipped design tokens; themes and `init.ss` replace any of them, and turning a plugin off takes its styles away. `describe-stylesheets` and `reload-stylesheets` inspect and reread them. The default look works on phones (dynamic viewport, safe areas, touch-sized targets) and in forced-colours mode. See [how Tuna works](overview.md#how-it-looks-html-and-stylesheets).

## Research before windows and scrolling

How the server learns layout facts from the browser (event-attached facts, measurement requests, Rocket components for local-only behavior). See [the capability-audit brief](briefs/2026-10-capability-audit.md).

## Later, roughly in order

1. *Done (2026-10-13): commands contract, `M-x`, completion ([brief](briefs/2026-10-completion.md)).* Still to do here: prefix-key help (which-key style), Consult-style sources and preview, Embark-style actions.
2. Windows: the window contract and the default layout-tree window manager ([desired design](ideas/window-management.md)), starting with a brief; `display-buffer`-style rules, window configurations, mode line; major and minor modes as plugins.
3. Real syntax highlighting and language-server integration as jobs and subprocesses.
4. First rich (non-text) buffer kind and navigation across nodes.
5. Attached REPL, `init.ss` reload, package reload.
6. Per-tab frames and input sessions; client-side reactivity where it pays off.
7. A settings screen, like Emacs's `M-x customize`: browse and change plugin settings through Tuna's interface; changes are saved as plain data in `custom.ss` and override `init.ss`.
8. Compressed screen stream: Brotli or Zstandard streaming compression of the SSE screen stream. Needs Gerbil packages equivalent to Racket's [libbrotli](https://docs.racket-lang.org/libbrotli/index.html) and [libzstd](https://pkgs.racket-lang.org/package/libzstd) (owner builds them). Makes the unchanged-screen resends the resource audit found (`agents/research/resource-audit-2026-10-15.md`) nearly free.
9. Files: find-file, save, revert, autosave; many buffers; buffer switching; large-file viewport.
10. The optional [profiler plugin](briefs/2026-10-profiler.md) (brief decided 2026-10-12), with service-operation advice.
