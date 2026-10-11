# Emacs Editor-API Analysis (language + primitives removed)

This re-runs the catalog analysis through an **editor-domain lens**. It strips
out Lisp-the-language and pure primitives — i.e. the categories
`control-flow-eval`, `lists-sequences`, `numbers-math`, `strings-chars`, and
`symbols-properties` — leaving only the APIs that exist *because Emacs is a
text editor* (buffers, point/mark, windows, syntax, display, modes, files,
processes, etc.).

Source: `emacs-api.csv` (GNU Emacs 30.2). Filtered subset written to
`emacs-api-editor.csv`.

## Headline numbers

| view | count |
|---|---|
| Full catalog (every symbol kind) | 19,087 |
| Editor-domain rows (language/primitives removed) | **16,507** |
| Editor-domain **documented public** surface (manual + non-internal + non-obsolete) | **4,034** |
| └ of which **callable** (function / command / macro) | **2,546** |
| └ of which **data** (variable / user-option / hook / keymap / face) | 1,488 |
| Callable public that are **C primitives** | 750 |
| Callable public that are **Elisp-level** | 1,796 |

So the honest "editor API parity" target is **~4,034 documented public symbols**,
of which **~2,546 are things you actually call** (the rest are variables /
options / faces / hooks / keymaps you'd expose as data). Not 19k.

## Callable public APIs by subsystem (the things you'd implement)

| count | subsystem |
|---|---|
| 622 | misc |
| 299 | text-editing |
| 299 | files |
| 218 | windows |
| 121 | modes |
| 118 | help-docs |
| 113 | syntax |
| 105 | frames |
| 99 | processes |
| 90 | search-regexp |
| 84 | buffers |
| 80 | abbrev-macros |
| 74 | faces-display |
| 68 | minibuffer |
| 43 | keymaps |
| 42 | options-customize |
| 35 | point-and-mark |
| 20 | mode-line |
| 14 | registers-bookmarks |
| 2 | completion |

(`completion` looks tiny because most completion machinery is tagged
`minibuffer` or `misc`; `misc` at 622 is the largest bucket and still mixes in
genuinely cross-cutting editor utilities plus symbols whose file couldn't be
resolved — `source_file` + `name` remain authoritative over `category`.)

## Full editor-domain surface by kind

| count | kind |
|---|---|
| 7185 | function |
| 3389 | variable |
| 3110 | command |
| 1477 | user-option |
| 357 | hook |
| 320 | macro |
| 271 | keymap |
| 257 | face |
| 105 | minor-mode |
| 32 | major-mode |
| 4 | special-form |

(These are *all* editor-domain rows, not just the documented-public subset.)

## How to read this for build sequencing

- The implementable core is **~2,500 callable APIs across ~18 subsystems**, not a
  flat 19k. Subsystems are independently buildable in dependency order.
- **750 are C primitives** — the irreducible runtime (buffers, markers, text
  properties, syntax, regexp, windows). **1,796 are Elisp-level**, i.e. composed
  from primitives; many come "for free" once the primitives + language exist.
- Any individual package leans on only a few subsystems (the
  `rainbow-delimiters` spike used exactly two: syntax + faces/display). Build
  subsystems in clusters and packages light up together.

## Reproduce

```sh
emacs --batch --no-init-file -l extract-emacs-api.el          # regenerates emacs-api.csv
# then re-derive emacs-api-editor.csv + these numbers from the CSV
```

The editor filter is: drop rows whose `category` is one of
`control-flow-eval, lists-sequences, numbers-math, strings-chars,
symbols-properties`. A few editor APIs that live in generic source files
(`make-local-variable` etc. in `data.c`, `syntax-after` in `subr.el`) are
rescued into their proper subsystem via name overrides in the extraction
script.
