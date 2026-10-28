# Research: Markdown rendering for Tuna's LLM chat

## Summary

Use **md4c**, vendored as two C files (`md4c.c`, `md4c.h`; MIT) and compiled straight into a small Gerbil foreign module. Use a C shim that runs `md_parse` and writes its events into one byte buffer, so the C code never calls back into Scheme. Scheme decodes the buffer into Tuna rich nodes or SXML (Scheme-expression XML), which the renderer escapes as usual. Pass `MD_FLAG_NOHTML` and allow only a few link schemes, so model output can never inject markup.

For streaming, keep the reply's raw Markdown as append-only text. Batch the incoming tokens and redraw about every 50 ms. Re-parse the whole message on each redraw at first; re-parse only from the last finished block once measurement shows the need. ADR 17 memoization then redraws only the blocks that changed.

For v1, don't highlight code. Draw a monospace `<pre><code>` block with a language attribute. Add tree-sitter later through the highlight layers Tuna already has.

## Findings

### Tuna constraints (repository evidence)

1. **Claim:** Markdown must be rendered on the server into nodes or SXML, not in the browser. **Sources:** `agents/adr/0007-rendering-and-transport.md` ("Tuna is a hypermedia application: plugins render their nodes to HTML…", "Node renderers … RENDER returns SXML", "Text is always escaped; only renderer code creates elements", "Authoritative editor state lives on the server"; it rejected a client-side editor component). **Support:** direct evidence. **Confidence:** high.
   - *Researcher inference:* two things rule out client-side Markdown (marked, streaming-markdown, Streamdown). First, every screen is a whole-screen Datastar morph, which would overwrite or flicker any DOM the browser changed itself. Second, key navigation, search and copy work on server-side nodes and their text projection (ADR 6).
2. **Claim:** The capability audit already planned the chat buffer as message nodes: the assistant message streams into a text node, code blocks become rich nodes with a copy button, and "Markdown [is] parsed incrementally in a job". **Sources:** `agents/research/capability-audit/04-package-stress-tests.md` row 88. **Support:** direct evidence. **Confidence:** high.
3. **Claim:** Rich nodes are drawn through `context-define-node-renderer!`, which returns SXML. Plugins already use it for buttons, help, the echo area, the terminal and the completion list. **Sources:** `plugins/renderer/plugin.ss:1-12`; `plugins/terminal/plugin.ss:2407-2419`; `plugins/help/plugin.ss:68`. **Support:** direct evidence. **Confidence:** high.
   - *Researcher inference:* the natural output is one rich node per Markdown block (paragraph, heading, list, table, code block), each with a text projection. Render inline spans as SXML elements (`strong`, `em`, `del`, `code`, `a`). Never send md4c's own HTML output: it would need a raw-HTML escape hatch that ADR 7 forbids.

### Candidates

4. **md4c (recommended).**
   - **Claim:** MIT licence; no dependencies. The parser is only `md4c.c` and `md4c.h` (7,464 + 495 lines at the checked commit); the optional HTML renderer adds 658 lines, and `entity.c` adds 2,186. It passes CommonMark 0.31.2. Flags turn on tables, task lists, strikethrough and permissive URL/WWW/email autolinks; `MD_DIALECT_GITHUB` bundles them with admonitions and footnotes.
   - It is designed for hostile input: it aims for near-linear time on pathological input and is fuzzed continuously by OSS-Fuzz. It is maintained: the last commit was 2026-10-19 (an O(n²) autolink fix), the last release is 0.6.0, and it is used by Qt, Blender and LibreOffice.
   - **Sources:** [mity/md4c README](https://github.com/mity/md4c); `src/md4c.h:391-423` and `CHANGELOG.md` in a clone at commit date 2026-10-19.
   - **Support:** direct evidence. **Confidence:** high.
   - **Safety:** `MD_FLAG_NOHTML` = `NOHTMLBLOCKS | NOHTMLSPANS` turns raw HTML off, so raw HTML reaches the application as ordinary text, which Tuna's renderer escapes. md4c does no URL scheme filtering (none found in `md4c-html.c`), so Tuna must allow only `http`, `https` and `mailto` itself. Entities arrive as verbatim `MD_TEXT_ENTITY` text (`md4c.h:229-232`): decode them, for example with the vendored `entity.c` table, or a reply showing `&amp;` will display literally.
   - **Limits:** it uses a push (SAX-style) callback API. It reports no source positions and has no incremental-parse API.
5. **cmark-gfm.**
   - **Claim:** BSD-2 plus bundled licences. About 25.7k lines of C in `src` plus `extensions` (table, strikethrough, autolink, tagfilter, tasklist). It builds an AST with source positions, and its build needs CMake.
   - Raw HTML is safe by default: it is dropped unless `CMARK_OPT_UNSAFE` is set, which also drops `javascript:` URLs (`cmark.h:609-621` in upstream cmark; the GFM fork inherits this).
   - Maintenance is weak. The last tagged release is `0.29.0.gfm.13` (July 2023), on CommonMark 0.29. Commits since are sporadic fixes (2025-12, 2026-07, 2026-09). Issue #228 (2021) asked "Is this project even active?"
   - **Sources:** [github/cmark-gfm](https://github.com/github/cmark-gfm), [releases](https://github.com/github/cmark-gfm/releases), [issue #228](https://github.com/github/cmark-gfm/issues/228); local clone `git log`.
   - **Support:** direct evidence. **Confidence:** high.
   - **Comparison:** source positions are its only real advantage. It is about 3.5× bigger and needs CMake plus extension registration. Upstream [cmark](https://github.com/commonmark/cmark), active and on CommonMark 0.31, has no GFM tables.
6. **Scheme-native options.**
   - **Claim:** none covers GFM.
     - [lexi-lambda/racket-commonmark](https://github.com/lexi-lambda/racket-commonmark) (ISC, about 3.1k lines of Racket) passes CommonMark 0.31.2, but its only extension is footnotes: no tables, strikethrough or task lists. Its last commit was 2024-10.
     - [greghendershott/markdown](https://github.com/greghendershott/markdown) (BSD-2) is not CommonMark-compliant (its README makes no compliance claim).
     - [guile-commonmark](https://github.com/OrangeShark/guile-commonmark) is LGPL-3 and its last commit was 2020.
     - Gerbil v0.19-dev-63's `std/text` holds only markup (html/sxml/xml) and parser modules; no Markdown parser was found.
   - **Support:** direct evidence (READMEs and docs `commonmark.scrbl:73`, licence files, git logs, `/opt/gerbil/.../lib/std/text`). **Confidence:** high.
   - *Inference:* porting racket-commonmark (it uses Racket-specific regexps and contracts) and then adding GFM tables and autolinks would be weeks of work against the spec and fuzz corpus that md4c already passes. It is not lean.
7. **Browser-side rendering** (marked, [streaming-markdown](https://github.com/thetarnav/streaming-markdown), [Streamdown](https://github.com/vercel/streamdown)).
   - **Claim:** these are good streaming renderers, but all of them own the DOM.
   - **Support:** direct evidence (READMEs). **Confidence:** high.
   - **Conflict:** this breaks ADR 7 (see finding 1). Rejected.

### Gerbil FFI pattern

8. **Claim:** Tuna's existing C dependency follows one pattern:
   - gerbil-libghostty is a separate package. It is linked into `.gerbil/pkg` by `make deps` (`gerbil pkg link …; gerbil pkg build gerbil-libghostty`, Makefile:44-47), not listed in `gerbil.pkg`'s `depend:`.
   - Its `build.ss` builds a pinned upstream commit (Zig) and stages a `.so` under `$GERBIL_PATH/lib/gerbil-libghostty/native`.
   - It compiles `private/ffi` with `-cc-options`/`-ld-options`, adding an `rpath` (run-time library search path) relative to the module.
   - A statically linked executable must recompile the binding's C, so it repeats those include and link options: `tuna/build.ss:70-77`, the helper executable.
   - **Sources:** Makefile; `build.ss`; `.gerbil/pkg/gerbil-libghostty/build.ss`; `scripts/build-native.sh`. **Support:** direct evidence. **Confidence:** high.
9. **Claim:** gerbil-libghostty records a known Gambit limitation: when overlapping Scheme→C→Scheme callbacks run on different Scheme threads, they can invalidate each other's C frames. The binding needed a library-wide native-entry gate because of it. **Sources:** `gerbil-libghostty/ghostty.md` §"Documented Gambit callback limitation" (cites `gambit.txi:19982-19992`). **Support:** direct evidence. **Confidence:** high.
   - *Inference / recommendation:* don't hand md4c Scheme callbacks (`c-define`). Instead write about 150 lines of C, `tuna_md_events(const char*, size_t, unsigned flags)`. Its callbacks append compact records to a `malloc`ed buffer: op (enter/leave block or span, or text), type, a few detail fields (heading level, code-fence language and info string, table alignment, task mark, link href), length and UTF-8 bytes. Copy the buffer into a u8vector with one `def-C-lambda` call (`U8_DATA`, as in `ffi.ss:197`), then free it. Scheme decodes the vector into nodes. This avoids callbacks, the native-entry gate and ownership of foreign objects.
10. **Claim (inference): the build is simpler than libghostty's.**
    - Vendor `md4c.c`, `md4c.h` and optionally `entity.c`/`entity.h` at a pinned commit, with the MIT `LICENSE.md`.
    - `#include` them in the foreign module's C and compile with `-cc-options "-I<native dir>"`. No `.so`, no rpath, no staging script.
    - **Package:** either a small `gerbil-md4c` package in the workspace, linked like gerbil-libghostty, or a private file of a future `markdown` (or `llm`) plugin.
    - Unlike the terminal helper, the main `tuna` executable will link this module, so `(exe: "main" …)` in `tuna/build.ss` needs the same `-cc-options -I…`.
    - Keep the parser behind its plugin's contract (`plugins/markdown/contract.ss`: "parse text → block records"). The kernel stays unchanged, which satisfies ADR 12.
    - **FFI effort:** about 1–2 days, including spec-sample tests.

### Streaming strategy

11. **Claim:** Pilish (dnouri/pilish, Emacs chat client for pi) keeps raw Markdown in the buffer and styles it with tree-sitter-markdown (md-ts). It batches per-token deltas and renders them every 0.05 s, because "Rendering every token … grows quadratically with message size". It tracks code-fence state character by character, and decorates tables only after a `|` appears. **Sources:** local checkout `~/.config/emacs/var/elpaca/sources/pilish/pilish-render.el:84-130, 291-401`; `pilish-grammars.el:46-49`. **Support:** direct evidence. **Confidence:** high.
12. **Claim:** Streamdown splits the message into top-level blocks with `marked`'s GFM Lexer (`parseMarkdownIntoBlocks`) and memoizes each block's render. Its `remend` package closes unfinished syntax before parsing: `**text` becomes `**text**`, a partial link points to a placeholder, and a partial image is removed. **Sources:** [vercel/streamdown](https://github.com/vercel/streamdown) `packages/streamdown/lib/parse-blocks.tsx:116,325`; `packages/remend/README.md`. **Support:** direct evidence. **Confidence:** high.
13. **Recommendation (inference):**
    - **v1:** store each assistant reply as an append-only text. Batch tokens every 50 ms, as Pilish does, using a Tuna timer or source. Each flush, re-parse the whole reply with md4c and rebuild its block nodes, giving each block a stable id by index. ADR 17 pieces reuse unchanged blocks' HTML, so only the last block or two are redrawn. md4c is linear, so this stays cheap for chat-sized replies; measure before optimizing.
    - An unclosed fence already behaves correctly while streaming: CommonMark runs an unclosed fence to the end of the document.
    - Add a tiny remend-style fix-up of the tail only if dangling `**` or `[` looks bad in practice.
    - **v2 (only if measured):** freeze blocks before the last blank line that lies outside a fence and is not inside a list, and re-parse only the tail. This assumes no later link-reference definition changes earlier blocks, which is rare in LLM output.

### Syntax highlighting

14. **Claim:** Tuna doesn't highlight code yet. Buffers do have named **highlight layers**: `set-highlights!` takes spans of face values, which move with edits, are set by jobs (`ranged-spans`), and are rendered as face classes through face-remapping. Only the terminal uses them today (`plugins/terminal/plugin.ss:1555`). No tree-sitter or syntax code was found in `plugins/` or `tuna/`. `docs/ideas/modes.md` plans per-node modes, for example a Markdown code block that carries its own mode. **Sources:** `plugins/buffers/contract.ss:88,215-256,454`; `plugins/renderer/plugin.ss:7,423-500`; grep. **Support:** direct evidence. **Confidence:** high.
15. **Recommendation (inference):**
    - **v1:** no highlighting. Draw code blocks as `<pre><code data-lang="…">`, styled monospace by the plugin's own `tokens.css`/`rules.css`, with a copy button.
    - **Later:** tree-sitter via FFI (as Pilish and Emacs do), computed in a job into a `syntax` highlight layer on the code block's text node. The renderer pipeline already supports this.
    - Avoid browser highlighters (highlight.js, Shiki): each fat morph would overwrite their DOM changes, against ADR 7.

## Contradictions

- cmark-gfm: GitHub's repository shows commits in 2025–2026, but no release since 2023-07, and issue #228 questions whether it is active. It is maintained enough for security fixes but stale against the spec (CommonMark 0.29).
- The task described md4c as "SAX callbacks". That's accurate, but Gambit's callback limitation makes calling md4c directly from Scheme riskier than its API suggests; the C shim (finding 9) resolves this.

## Missing evidence

- No benchmark of md4c parse time on 10–50 KB chat replies. The near-linear claim comes from md4c's own README; measure inside Tuna.
- Exactly how `MD_FLAG_NOHTMLSPANS` reports `<script>` text (as `MD_TEXT_NORMAL`) was inferred from `md4c.c:3430`, not tested. Add a test that feeds `<script>`, `<img onerror>`, `javascript:` links and entity tricks.
- Whether a Scheme-to-C call of under 1 ms that blocks all Gambit green threads matters at the 50 ms cadence (probably not).
- No decision yet on whether the chat buffer keeps the reply as an editable raw text node shown through a "display replaces rendering" decoration (capability audit CR1) or as rich nodes with a text projection. That decision belongs to the `llm` brief.

## Sources

- **Kept:**
  - [mity/md4c](https://github.com/mity/md4c) README, `md4c.h` and CHANGELOG: licence, flags, safety, maintenance.
  - [github/cmark-gfm](https://github.com/github/cmark-gfm) and its [releases](https://github.com/github/cmark-gfm/releases): maintenance and extensions.
  - [commonmark/cmark](https://github.com/commonmark/cmark) `cmark.h`: safe-by-default semantics.
  - [lexi-lambda/racket-commonmark](https://github.com/lexi-lambda/racket-commonmark), [greghendershott/markdown](https://github.com/greghendershott/markdown), [guile-commonmark](https://github.com/OrangeShark/guile-commonmark): Scheme options.
  - [vercel/streamdown](https://github.com/vercel/streamdown) and remend: block-memoized streaming.
  - [thetarnav/streaming-markdown](https://github.com/thetarnav/streaming-markdown): browser streaming parser (rejected, but shows the pattern).
  - The local Pilish checkout: the Emacs streaming approach.
  - Tuna ADR 6, 7, 12 and 17, `docs/overview.md`, the capability audit, `build.ss`, the Makefile, and gerbil-libghostty (`build.ss`, `ghostty.md`, `private/ffi.ss`).
- **Rejected or deprioritized:**
  - The system `libmd4c0` 0.4.8 package: old, no headers; vendor a pinned copy instead.
  - Web search results: the providers were mostly unavailable, so primary repositories were cloned and read directly instead.

## Next steps

- Prototype the md4c C shim and the byte-buffer decoder. Test it on the GFM spec samples (`test/spec-tables.txt`, `spec-tasklists.txt`, `spec-strikethrough.txt`, `spec-permissive-autolinks.txt`) and on a hostile-HTML corpus.
- Time a full re-parse of a 50 KB reply inside Tuna to confirm v1 needs no tail-only parsing.
- In the `llm` brief, settle whether a reply is a raw text node with a rendering decoration or rich block nodes.
