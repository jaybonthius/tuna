# Stylesheets plan, stages 4–5: report

Worktree `/home/jay/Code/workbench-gerbil/tuna__stylesheets-delivery`, branch `stylesheets-delivery`. Nothing was pushed. The kernel is unchanged. `make test` passed under `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 2400` after each stage. Each run took about 2 min 45 s and its last line was `OK`.

## Commits

| Stage | Commit | Subject |
|---|---|---|
| 4 | `25d8f10` | web: serve stylesheets and morph the page head |
| 5 | `d308555` | design-tokens: ship Stellar's default tokens as a stylesheet |

## Stage 4: delivery by the web transport (`plugins/web/plugin.ss`)

The web plugin imports the stylesheets contract, which has no service, so it declares nothing new. It still requires no other plugin.

**URLs.** Each stylesheet is served at `/css/<n>/<sha256>/<file>`:
- `n` is a stable slot number, assigned the first time the web server sees an `(owner . name)` and kept while that server runs. Turning a plugin off and on again keeps its number, and inserting a stylesheet earlier in the page does not renumber the later ones.
- `<sha256>` is the registry's digest, written out in full.
- `<file>` is the URL-encoded file name.
- The response has `Content-Type: text/css; charset=utf-8` and `Cache-Control: public, max-age=31536000, immutable`.
- Any other `/css/...` prefix gets 404, including a stale hash, a wrong `n` and a bare `/css/`.
- A stylesheet whose file cannot be read has no digest and is not linked. Stage 2 already reports it as a warning.

**Assets.** Other paths under a stylesheet's current prefix are served from the stylesheet file's own directory:
- Each one gets an `ETag` (size and modification time) and `Cache-Control: no-cache`, and `If-None-Match` gets 304.
- MIME types come from `:std/net/mime/file`. Only `font/*`, `image/*` (plus `.webp`, which Gerbil's table lacks) and `text/css` are served.
- Refused with 404: empty segments (this covers absolute paths such as `prefix//etc/hosts`), `.` and `..`, any `%` or `\` (so `%2e%2e` cannot spell `..`), directories, missing files and every other file type. The type rule means a request cannot read `plugin.ss` or `init.ss` beside a stylesheet.
- Symlinks are followed. The checks are on the path text only.

**Head.** One function, `render-head`, renders the whole `<head>`: the metas, the title, `<link id="tuna-css">` for `/static/tuna.css` first, one `<link rel="stylesheet">` per served stylesheet in page order, the importmap and the module script. The first page embeds its output, and every head morph sends the same string.
- **Link ids:** `css__<owner>__<name>`. Every character other than a letter, digit or `-` is written as `_XX` in hex, so `PLUGIN/config` becomes `PLUGIN_2fconfig`. The encoding is injective, and `__` never appears inside an encoded part, so no two stylesheets share an id. init.ss's own stylesheet came out as `css__init__mine`.

**Threads.** `{redisplay! web-server}` runs on the editor thread with the baton.
- It calls `(stylesheets-generation)`. Only when that differs from the generation the server last rendered does it read `(stylesheets)` and build the served list (bytes encoded once per change) and the head string.
- It publishes the head and served list under the same lock and broadcast as the screen.
- Request threads never read the registry. `/css/` requests search the published served list, and asset requests read files from the directory recorded there.
- At activation the head has no stylesheet links: the server does not touch the registry until the first redisplay, which the loop does immediately when it starts.

**Streams.** `await-screen` returns `[revision head screen]`. Each stream writer remembers the head it last sent. When the head differs it sends the head first as one `patch-elements`, then the screen. A new stream's remembered head is empty, so its first event is always the head, before the first screen; that holds for a reconnect too. Links are never patched one at a time.

**Tests** (new file `plugins/web/tests/integration/web-stylesheets-test.ss`). A test plugin, `web-test/styled` (an owner with a slash), adds one stylesheet from a temporary directory. The cases:
- the head links it after tuna.css and before the scripts, by the expected sanitised id and URL;
- its URL serves the text with the exact headers, and a stale hash, a wrong slot and `/css/` get 404;
- a font beside it is served with `font/woff2`, `no-cache` and an ETag, and 304 on revalidation; `other.css` is served as CSS; `../style.css`, `fonts/../other.css`, `./other.css`, `%2e%2e/…`, `//etc/hosts`, `fonts//x.woff2`, `fonts`, `secret.ss` and a missing file all get 404;
- a stream that opens receives the head (identical to the page's head) before the screen;
- after the file changes and `reread-stylesheets!` runs, the stream receives a head morph with the new URL followed by a screen, the old URL gets 404, the new one serves the new text, and the page links the new URL.

`web-test.ss` passes unchanged.

### The head-morph choice: the whole `<head>`, scripts reproduced identically

I chose the whole head over a dedicated container:
- **No container is possible in `<head>`:** it allows no grouping element.
- **A container in `<body>` would weaken the first paint:** links are body-ok, but a parser-created link in `<body>` is not render-blocking per the HTML standard. Body content can then paint unstyled on first load, whereas links in `<head>` are render-blocking. Keeping the links in `<head>` keeps the first paint correct.

**What Datastar v1.0.2 does, read from the vendored bundle (`plugins/web/web/datastar-v1.0.2.js`):**
1. Elements containing `</head>` are parsed as a document, and the `<head>` element targets `document.head` in outer mode.
2. The morph matches old and new nodes by tag, and by id where the old node has one. Elements with ids present before and after are kept and moved, not recreated.
3. A matched element has only its changed attributes set, and subtrees that are `isEqualNode` are left alone.
4. After the morph, Datastar re-creates (and so re-executes) any `<script>` under the target that is not in its `WeakSet` of known scripts. That set holds every script present when the Datastar module loaded, which includes both of Tuna's head scripts.

**Why the scripts survive.** The same function renders the head every time, so the scripts are byte-identical. Every link has an id, including tuna.css, so a new link can never be soft-matched onto an old element. The scripts therefore match themselves, compare equal, stay the same elements and are never re-created.

**Browser check.** The page saved the head's `<script>` and `<link>` element objects, then ran `M-x reload-stylesheets` after a CSS file changed. Afterwards the scripts were the same objects, the links were the same objects with only the changed `href`, only the changed stylesheet was fetched, the new rule applied, the page did not reload (the saved objects survived), and the console showed no messages.

## Stage 5: the design-tokens plugin (`plugins/design-tokens/`)

**Files:**
- `tokens/stellar-default.css` and `tokens/stellar.config.json` are byte-for-byte copies of the scratch files (checked with `cmp` against the commit).
- `plugin.ss` defines `design-tokens`, which runs `(add-stylesheet 'tokens "tokens/<variant>.css")`. The path resolves against `plugin.ss`'s own directory.
- `design-token-variants` is `'(stellar-default)`. The `variant:` option has a local `option-type` that accepts only those symbols, described as "one of: stellar-default". A typo in init.ss is reported as `init.ss line 3: design-tokens option variant must be one of: stellar-default`.

**`make tokens`** runs `cd plugins/design-tokens/tokens && $(STELLAR) gen --input stellar.config.json`, with `STELLAR ?= stellar`; pass an absolute path for a binary that is not on `PATH`. The config's `settings.export.output` is `stellar-default.css`, and the target runs in that directory. The Makefile comment and the guide say that the binary and its key are not in the repository and that normal builds never need them. Nothing in the build or the tests runs the binary.

**The token subset** is in `agents/guides/design-tokens.md`. It gives naming patterns and ranges read from the generated file:
- `--P-N`, `-on` and `-dim` for the six palettes, N from 1 to 12;
- `--size-N` (-2 to 12), `--font-size-N` (-2 to 12) and `--font-line-height-N` (-3 to 4);
- `--font-sans`, `--font-serif` and `--font-mono`, and the ten font weights;
- `--border-width-N` (0 to 5), `--border-radius-N` (0 to 6), `--shadow-N` (0 to 6) and inset `--shadow--N` (1 to 4);
- the named durations (none, instant, fast, base, slow, long) and four easings (standard, emphasized, entrance, linear);
- the 43 `--code-*` names.

It also lists what is defined but left out.

**Configuration.** `(use-plugin design-tokens variant: stellar-default)` comes first in `starter/init.ss` and `demo/init.ss`. `build.ss` builds the plugin after the stylesheets contract. Boot-test's expected starter list now starts with `design-tokens`, checks its options, and looks for web-transport's port at index 3.

**Tests** (`plugins/design-tokens/tests/integration/design-tokens-test.ss`):
- `design-token-variants` names files that exist; init.ss accepts `variant: stellar-default` and an omitted option, and rejects a typo with its line;
- the plugin registers exactly `(design-tokens tokens)` with that path, no warning, and the file's text;
- the shipped file defines every name in the documented subset, so a regeneration that drops one fails the tests.

## Validation

- `make test` passed after stage 4 and after stage 5 (last line `OK`, exit 0).
- **Browser checks** used agent-browser and Chrome. Tuna ran from `.gerbil/bin/tuna` with temporary `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME` and `XDG_RUNTIME_DIR`, on explicit free ports. Each process was stopped by its PID, and `pgrep` confirmed none remained.
  - **Stage 4** used a copy of the demo config with an extra init.ss `add-stylesheet`. Typing worked. Editing that CSS file and running `M-x reload-stylesheets` changed the link and the computed style without a reload, with the scripts and link elements kept as described above.
  - **Stage 5** used `demo/init.ss` itself:
    - the head links were `tuna-css`, then `css__design-tokens__tokens`, in that order;
    - the Stellar URL returned 200, `text/css; charset=utf-8`, immutable, 61,196 bytes, and `--primary-3` resolved on `:root`;
    - typing showed "typed";
    - appending a rule to `stellar-default.css` and running `M-x reload-stylesheets` gave a new link URL, applied the new custom property, fetched only that file, kept the scripts and link elements, and did not reload the page; the old URL then returned 404;
    - the file was restored from the scratch copy before the commit (verified with `cmp`).
  - The screenshot looks as it did before: tuna.css is still first, and the Stellar file only defines custom properties plus an `.animate` helper.

## Deviations and decisions to confirm

1. **Stage 4 tests live in a new file**, `web-stylesheets-test.ss`, beside `web-test.ss`, using its HTTP client. The task allowed this.
2. **Assets are served only under the current hash.** A request under an old prefix gets 404, like the stylesheet. In the short window after a reread, a font requested by the old sheet would 404; the new sheet requests it under the new prefix.
3. **Asset types are an allowlist** (fonts, images, CSS). Without it, any file beside a stylesheet, such as `plugin.ss` or `init.ss`, would be readable over loopback. Asset paths containing `%` are refused, so file names that need percent-encoding (spaces, non-ASCII) cannot be served as assets. Stylesheet file names themselves are URL-encoded in the href and match.
4. **The first page served before the first redisplay links no stylesheets.** This keeps registry reads on the editor thread. The loop redisplays as soon as it starts, and the stream sends the corrected head before the first screen, so this matters only if a page loads in that instant.
5. **The token subset is narrower than the file in places:**
   - it includes only `--font-sans`, `--font-serif` and `--font-mono` (not Stellar's other named stacks);
   - it leaves out the in-between radii and the numbered durations;
   - it includes only four of the eight easings;
   - it leaves out letter spacing, z-index, aspect ratio and the other animation values.

   The aim is to keep the mapping to another design system small. Widen it if stage 6 needs more.
6. **The starter and demo write `variant: stellar-default` explicitly**, which matches the brief's example. It is also the default.
7. **`make tokens` was not run.** The instructions forbid running the binary in the build or the tests. I ran `stellar --help` and `stellar gen --help` (from `/home/jay/Code/shux/stellar`) once, only to learn its flags (`--input`). The key's location was not checked. Shux's notes say the binary and `stellar.key` sit together, so the owner may need `STELLAR` to point at a binary whose key it can find.

## Open risks

- The Stellar redistribution question (review P2-7) is still open for publishing. The owner approved committing the file.
- The flash-of-unstyled-content analysis is unchanged. A newly added link (a plugin turned on at runtime) can paint briefly unstyled until its sheet loads, because a link inserted after the body exists is not render-blocking.
- Not checked: Firefox and Safari. Chrome has `moveBefore`, so a reordered link is moved without a re-fetch. Engines without it fall back to `insertBefore`, which re-fetches the sheet and may flash.
- The Gerbil MCP tools were unavailable. Balance was checked by reading every form with `gxi`, and syntax by building.
