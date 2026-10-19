# Stylesheets plan, stages 1–3: report

Worktree `/home/jay/Code/workbench-gerbil/tuna__stylesheets-registry`, branch `stylesheets-registry`. Nothing pushed. The kernel is unchanged (`git diff c4f492d -- tuna/kernel tuna/kernel.ss` is empty). `make test` passed under `systemd-run … MemoryMax=8G … timeout` after each stage.

## Commits

| Stage | Commit | Subject |
|---|---|---|
| 1 | `ecb6639` | renderer: make HTML the only presentation language |
| 2 | `72d5f94` | stylesheets: add the registry contract |
| 3 | `c6332a6` | stylesheets-help: describe and reload stylesheets |

## Stage 1: HTML is the presentation language

- ADR 7 is amended. It records the owner's 2026-10-16 decision: Tuna is a hypermedia application, HTML is the only presentation language, and the renderer returns HTML. A terminal frontend would render HTML as text. The "terminal renderer later" clause is struck through.
- `context-define-node-renderer! ctx kind render` and `node-renderer kind` no longer take a target. The entry-table slot is the kind. Every caller and test was updated: buttons, completion-vertical, echo-area, help, minibuffer, the renderer, tree-buffer, html-renderer-test and buttons-test.
- `plugins/renderer/tests/support/plain-text-renderer.ss` and the `.plain-text` rules in `tuna.css` are deleted.
- The swap proof is kept by `plugins/renderer/tests/support/bare-renderer.ss`, a roughly 70-line second HTML renderer. It draws every node fresh, with no reuse, no node ids, a `<pre class="text">` per text node, and `data-renderer="bare"` on the screen. `tests/integration/renderer-swap-test.ss` runs its 4 cases against it: swap and back, node kinds, two views, and the prompt. `C-c v` in swap-commands now says "Renderer: bare".
- The overview line and the test-doubles line now name the bare renderer. TODO.md no longer mentions the plain-text renderer.

## Stage 2: `plugins/stylesheets/contract.ss` (contract only, no service)

**API.** `(add-stylesheet [ctx] name path)` and `(replace-stylesheet [ctx] owner name path)`, where path `#f` removes. Both are macros modelled on `keymap-set`. The context argument is optional and defaults to `(current-context)`, so the same forms work in plugins, themes, `config:` blocks, init.ss user code and evaluated code.

**Queries:**
- `(stylesheets)` returns the page in order. Each entry has owner, name, path, text, a SHA-256 hex digest (`:std/crypto/digest`), replaced-by and warning.
- `(stylesheet-replacements)` returns each replacement in effect, with its target `present`, `absent` or `dormant`.
- `(stylesheets-generation)` is the change counter.
- `(reread-stylesheets!)` rereads every file and returns how many changed.

**Registry:**
- Slots are `(owner . name)` in an owner-tagged entry table. The owner's own file has priority 0 and a replacement priority 1; ties go by init.ss rank, read when the registry is read.
- A second `owners` entry table gives page order by rank, using the same one-slot trick as `tuna/lib/advice.ss`. Within one owner, order follows entry serial (registration order).
- Turning a plugin off removes its entries through receipts, which restores whatever it replaced.

**Paths:**
- The macro records the directory of the file holding the form, using `stx-source-file` from `:std/source`. A relative path, literal or computed, resolves against that directory. Compiled plugins record absolute source paths, which I checked in `.gerbil/lib/...scm`.
- The text is read at registration.
- A missing or unreadable file leaves the stylesheet on the page with no text, no digest and a warning. It never fails activation.

**Scope.** The registry is module state, as advice targets are. Tuna runs one editor per process, and `call-with-fresh-kernel` turns every plugin off, which empties the registry. The header comment says so.

**Declarations.** `tuna/plugin-use.ss` counts only modules exporting service values, so styled plugins need no `requires:`.

**Tests:**
- `plugins/stylesheets/tests/unit/stylesheets-test.ss` covers add (order, text, digest), replace, remove with `#f`, restore on theme off, dormant replacement, page order following ranks (with the generation changing), the later-declared replacement winning, missing file, and reread (including a deleted file).
- `plugins/stylesheets/tests/integration/stylesheets-config-test.ss` uses a real init.ss loaded by `start-from-configuration`:
  - init.ss `add-stylesheet` and `replace-stylesheet` resolve relative to init.ss, and init.ss beats a theme;
  - a reload that reorders the declarations reorders the page;
  - evaluated code needs an absolute path.
- Support files: `plugins/stylesheets/tests/support/styled.ss` plus a `css/` directory.

## Stage 3: `plugins/stylesheets-help/plugin.ss`

**Requires** `commands-service` and `help-service`. It imports the kernel, the commands, help and stylesheets contracts.

**`describe-stylesheets`** shows in *Help*:
- "On the page, in order:", one line per stylesheet with `(owner name)`, path and "replaced by X";
- "Removed:", for `#f` replacements of present stylesheets;
- "Warnings:", which lists:
  - unreadable files;
  - a replacement whose owner is on but does not add that name (dormant replacements are not reported);
  - `var(--x)` without a fallback that no stylesheet on the page defines. The scan strips `/* */` comments, skips the whole fallback of a `var()` (so names used only inside a fallback are ignored), and counts `--x` followed by a colon as a definition.

**`reload-stylesheets`** rereads all files.

**Echo area.** One line is shown when a check fails: "Stylesheets: N warnings; see *Help*", or on reload "Stylesheets reread: N changed; M warnings, M-x describe-stylesheets lists them".

**Configuration.** The plugin is added to `build.ss`, `starter/init.ss` and `demo/init.ss`, and to boot-test's list of starter plugins.

**Tests** (`plugins/stylesheets-help/tests/integration/stylesheets-help-test.ss`): page order with a variable defined in another sheet and no message; replacement listing, the absent-target warning with the echo line, and the removal listing; the var() scan (comments, fallbacks, nested fallback, spaces, duplicates); an unreadable file; reload before and after a file changes.

## Deviations and decisions to confirm

1. **Interactive code requires absolute paths.** The task allowed this; it was simpler than finding init.ss's directory from a contract. A relative path from code without a source file raises an error at evaluation.
2. **"Owner is on" means the owner has a stylesheet of its own registered.** The registry cannot see plugin activity otherwise without a context or a kernel query by name. Consequence: a replacement aimed at a plugin that is on but registers no stylesheets at all counts as dormant, so warning (a) misses it.
3. **stylesheets-help does not use the completion contract.** Nothing is chosen, unlike `describe-advice`.
4. **Contract-only package.** `tuna/tests/unit/boundary-test.ss` required `plugin.ss` in every `plugins/*` package. It now checks the prelude only where `plugin.ss` exists, because `plugins/stylesheets` has only `contract.ss` (the brief places the commands in a separate `stylesheets-help` package).
5. **Layout's `render-layout` still takes a target** (`'html`, or `'test` in layout and view-commands tests). This was outside the "node renderers" scope. It is a candidate follow-up, since HTML is now the only target.
6. **The generation is read-driven.** `stylesheets-generation` compares the page's registrations (identity and order) with the last read, and a reread that changes a file bumps it. This means a reload that only reorders init.ss also changes it. It mutates module state when read, so stage 4 must call it on the baton (or add a lock) if web request threads read it.
7. **`(stylesheets)` omits removed slots.** Removals appear through `stylesheet-replacements` (path `#f`).
8. **Self-replacement is an error.** `replace-stylesheet` naming the calling plugin as owner raises an error; use `add-stylesheet` instead.
9. **Unreadable files count as warnings.** They appear in describe's Warnings and in the echo-line count, as well as on the slot.
10. **Commit placement.** Exporting the `stylesheet` and `stylesheet-replacement` type names, needed for annotations in the help plugin, landed in the stage 3 commit.

## Things I was unsure about / observed

- The first full `make test` run in stage 3 hit a failure in `tests/integration/reload-test.ss` ("a changed user module replaces its plugin": the reload saw no change, probably mtime resolution while the machine was under load from another Gerbil build). Then `boot-test.ss` hung until the timeout. Alone, boot-test passes in 10 s, and the immediate full rerun passed in 2.5 minutes. I treated this as a pre-existing flake and did not investigate further.
- I did not do a browser check. Stages 1–3 change no delivery: the web transport still serves `tuna.css` unchanged except for the removed `.plain-text` rules. `make test`'s demo-check loads the demo configuration with the new plugin.
- The Gerbil MCP tools were not available. Balance was checked by reading forms with gxi, and syntax by building.
