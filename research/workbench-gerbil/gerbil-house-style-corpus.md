# Empirical Gerbil authored-source house style

## Conclusion

The current `fixw-gerbil` output is structurally conservative but not stylistically conservative for the pinned Gerbil corpus. Across 483 authored `.ss` files, it changes 417 files and 32,521 of 84,951 physical lines.

The dominant losses are:

1. first-argument continuation anchors, especially `import`, `export`, `and`, and `or`;
2. one-column `cond` clauses;
3. missing structural handling for `def*` and `defcompile-method`;
4. deliberate intra-line alignment in typed formals, tables, keyword/value columns, and comments.

Ordinary `def`/`defmethod` bodies, binding-list indentation, and most `match` and syntax-case clause layouts already agree well with authored practice.

Gerbil has no normative formatter specification: it documents two-space indentation and following surrounding code at `gerbil/CONTRIBUTING.md:191-195`. These findings are therefore empirical house style, not language requirements.

## Scope and provenance

Compared:

- Original: `/home/jay/Code/workbench-gerbil/gerbil`
- Formatted: `/tmp/gerbil-fixw-run-CW0cop/gerbil`
- Commit for both: `4a4d1a3059824adf6319105bde496bef00d09834`

Included authored roots:

- `src/gerbil`
- `src/std`
- `src/lang`
- `src/tools`
- `src/tutorial`

Excluded generated bootstrap, vendored Gambit, `src/v0.19-WIP`, and non-`.ss` sources. Three position-zero `#lang` files are included in headline totals but are formatter passthroughs.

The original checkout has no tracked changes in the five roots. Untracked generated test artifacts exist but are not `.ss` corpus inputs. The formatted tree has exactly 417 modified authored `.ss` files.

### Headline totals

| Root | Files | Changed files | Physical lines | Changed lines |
|---|---:|---:|---:|---:|
| `src/gerbil` | 95 | 70 | 33,758 | 13,518 |
| `src/std` | 320 | 294 | 44,458 | 16,109 |
| `src/lang` | 2 | 2 | 42 | 2 |
| `src/tools` | 32 | 30 | 5,630 | 2,573 |
| `src/tutorial` | 34 | 21 | 1,063 | 319 |
| **Total** | **483** | **417** | **84,951** | **32,521** |

Line-change classes:

| Class | Lines |
|---|---:|
| Leading indentation only | 28,487 |
| Intra-line spacing only | 2,673 |
| Both | 1,361 |
| **All changed** | **32,521** |

Excluding the two checked-in `.ssxi.ss` files still leaves 30,716 of 83,005 lines changed, so generated-looking metadata does not explain the result.

## Empirical findings

### 1. `import` and `export` continuation anchors — high severity

A broad classifier found 454 multiline `import` forms:

- 425 attach the first operand to the head line;
- 29 put the first operand on the following line;
- attached-first forms contain 1,458 direct continuation lines whose leading indentation changes;
- the 144 direct continuation lines in head-only forms have zero indentation mismatches.

A stricter structural subset found that, among eligible attached-first imports, 299 align under the first operand, 13 are mixed, and one is a one-column exception. The dominant form is:

```scheme
(import "../core/expander"
        "../expander")
```

Original: `gerbil/src/gerbil/compiler/base.ss:8-10`  
Formatted: `/tmp/gerbil-fixw-run-CW0cop/gerbil/src/gerbil/compiler/base.ss:8-10`

The established secondary form remains two-space indented:

```scheme
(import
  "expander/common"
  "expander/stx"
  ...)
```

Evidence: `gerbil/src/gerbil/expander.ss:14-23`.

There are 88 multiline `export` forms. Fifty-nine eligible forms align continuations under the first operand; all 59 lose that anchor. Nested export transformers also occur at `gerbil/src/gerbil/expander.ss:25-31`.

Cause:

- rule-zero declarations: `fixw-gerbil/private/rules.ss:11-14`;
- active numeric rules force `opener+2`: `fixw-gerbil/private/formatter.ss:50-55,66-83`.

The same mismatch affects authored first-argument alignment for `and`, `or`, `map`, `for-each`, `foldl`, and `foldr`.

### 2. Multiline typed `def` formals — high severity for horizontal alignment

Among 440 eligible multiline `def` signatures, 339 align later arguments beneath the first actual argument. That vertical signature alignment usually survives.

What does not survive is alignment of type markers within formal rows. A conservative typed-formal classifier found:

- 208 multi-formal typed `def` groups;
- 177 originally aligned marker groups;
- 169 become unaligned;
- 315 formal lines are affected.

Exact example:

```scheme
(def (URL-from-components (proto   : :string)
                          (host    : :string)
                          (target  : :string)
                          (address :? Address := #f))
```

Original: `gerbil/src/std/net/url.ss:160-163`  
Formatted: `/tmp/gerbil-fixw-run-CW0cop/gerbil/src/std/net/url.ss:160-163`

Suffix-keyword formals combine vertical argument and keyword-label alignment:

```scheme
(def (vector-least-index (pred? : :procedure)
                         (vector : :vector)
                         start: (start : :fixnum := 0)
                         end: (end :? :fixnum := #f))
```

Evidence: `gerbil/src/std/vector/vector.ss:32-35`.

Cause: ordinary same-line token boundaries are regenerated with exactly one space at `fixw-gerbil/private/formatter.ss:104-116`.

### 3. Ordinary `def`, `def*`, and `defcompile-method`

#### Ordinary `def`

Of roughly 4,950 structural `def` forms, 3,525 have all direct body continuations at `opener+2`; 721 have no multiline continuation and 689 are mixed. The existing `def` rule at `fixw-gerbil/private/rules.ss:33` broadly matches authored bodies.

#### `def*` — high severity

All 22 structurally parsed `def*` forms place clauses at `opener+2`. Twenty-one of 22 instead become aligned under the procedure name, causing at least 59 clause/body indentation changes.

Original:

```scheme
(def* foldl
  ((f iv lst)
   ...)
  ((f iv lst1 lst2)
   ...))
```

Original: `gerbil/src/gerbil/runtime/util.ss:285-291`  
Formatted: `/tmp/gerbil-fixw-run-CW0cop/gerbil/src/gerbil/runtime/util.ss:285-291`

`def*` is absent from `fixw-gerbil/private/rules.ss:33-39`, so generic fallback reuses the saved first-argument column at `private/formatter.ss:83-95`.

#### `defcompile-method` — high severity

All 46 eligible authored forms place continuation items at `opener+2`. All 46 become aligned under the long signature argument, often at column 19. Approximately 575 changed lines have immediate `defcompile-method` context.

Original dispatch table:

```scheme
(defcompile-method (apply-collect-top-level-type-info)
  (::collect-top-level-type-info ::void)
  ()
  final:
  (%#begin            apply-begin%)
  (%#begin-syntax     apply-begin-syntax%)
  ...)
```

Original: `gerbil/src/gerbil/compiler/optimize-top.ss:22-37`  
Formatted: `/tmp/gerbil-fixw-run-CW0cop/gerbil/src/gerbil/compiler/optimize-top.ss:22-37`

The output both moves the complete body beneath the signature and collapses the dispatch-table columns.

### 4. `cond` versus other clause forms — high severity

Of approximately 905 `cond` forms with list clauses:

- 850 place every clause opener at `cond opener+1`;
- only two use pure `opener+2`;
- the formatted output changes 860 forms to `opener+2`;
- approximately 2,556 leading-only changes occur in immediate `cond` context.

Original and formatted comparison:

- `gerbil/src/gerbil/main.ss:180-199`
- `/tmp/gerbil-fixw-run-CW0cop/gerbil/src/gerbil/main.ss:180-199`

Authored form:

```scheme
(cond
 ((predicate)
  body)
 (else
  body))
```

`cond` is absent from `fixw-gerbil/private/rules.ss:6-39`; generic second-item behavior selects `opener+2` at `private/formatter.ss:71-78`.

This is specifically a `cond` convention. Other clause forms already fit the two-space structural convention:

- about 426 of 449 `match` forms use pure `opener+2`;
- 239 of 275 `syntax-case` forms use pure `opener+2`;
- 222 of 269 `ast-case` forms use pure `opener+2`;
- all 95 eligible `defsyntax-case` forms use pure `opener+2`.

Representative evidence:

- `gerbil/src/gerbil/runtime/util.ss:273-283`
- `gerbil/src/gerbil/core/sugar.ss:193-212`
- `gerbil/src/gerbil/expander/stxcase.ss:118-134`

### 5. Binding lists — strong, already preserved

Of 1,023 multiline classic `let`, `let*`, and `letrec` binding lists:

- 1,004 (98.1%) put later bindings at the binding-list opener plus one;
- 19 are mixed or contextual;
- formatted output canonicalizes all 1,023 to local `opener+1`.

Example: `gerbil/src/gerbil/main.ss:129-132`.

Bracketed settings data follow the same local one-column convention:

- original: `gerbil/src/std/misc/process.ss:57-66`
- formatted: `/tmp/gerbil-fixw-run-CW0cop/gerbil/src/std/misc/process.ss:57-66`

The enclosing form can move, but bracket children remain one column beyond `[`.

### 6. Vertical argument alignment — mixed global result

Across 21,379 eligible forms with a head-line first argument and later direct arguments:

| Layout | Authored | Formatted |
|---|---:|---:|
| Align beneath first argument | 2,679 | 2,367 |
| `opener+2` | 15,140 | 15,790 |
| `opener+1` | 35 | 25 |
| Mixed | 3,525 | 3,197 |

Highest-frequency authored first-argument-aligned heads include:

| Head | Aligned forms |
|---|---:|
| `and` | 420 |
| `import` | 299 |
| `or` | 238 |
| `cons` | 105 |
| `export` | 59 |
| `map` | 44 |
| `for-each` | 40 |
| `foldl` | 9 |

This demonstrates that first-argument alignment is established practice, but not a universal layout: structural bodies, clauses, and binding data intentionally use different anchors.

### 7. Deliberate same-line multi-space tables and comments — high severity

A conservative code-line scan found:

- 3,824 lines with an internal run of two or more spaces/tabs;
- 4,697 such runs;
- 3,704 lines (96.9%) change;
- at least 1,767 table-row lines;
- at least 1,293 typed-column lines;
- at least 420 keyword-column lines;
- 324 aligned inline-comment lines, of which 305 change.

Examples:

- command/dispatch tables: `gerbil/src/gerbil/main.ss:57-85`;
- compiler dispatch table: `gerbil/src/gerbil/compiler/optimize-top.ss:22-37`;
- typed and keyword columns: `gerbil/src/std/serde/deserialize.ss:542-547`;
- aligned inline comments: `gerbil/src/gerbil/runtime/control.ss:73-87`.

The formatter’s unconditional one-space fallback is `fixw-gerbil/private/formatter.ss:104-116`.

Tabs are a material exception: 1,048 tabs occur on 752 lines in 36 files; 738 tab-bearing lines change. Large indentation deltas therefore sometimes include tab expansion rather than a pure authored-space convention.

### 8. Brackets and braces

Gerbil maps brackets to `@list` and braces to `@method` at `gerbil/src/gerbil/runtime/syntax.ss:288-299`.

#### Brackets

The corpus contains approximately:

- 3,574 actual `[` openers;
- 571 multiline bracket forms;
- 384 authored multiline forms with pure local `opener+1`;
- 547 formatted forms with pure local `opener+1`.

The formatter generally preserves or canonicalizes bracket data, though syntax templates can intentionally align to an outer construct. Evidence:

- settings data: `gerbil/src/std/misc/process.ss:57-66`;
- syntax templates: `gerbil/src/gerbil/core/match.ss:287-307`.

Bracket-specific behavior is implemented at `fixw-gerbil/private/formatter.ss:61-64,73-82`.

#### Braces

There are 310 actual brace openers on 309 code lines, but no multiline actual `{...}` form was found. Compact method syntax is well attested:

```scheme
(defmethod {add-x A}
  ...)
```

Evidence: `gerbil/src/tutorial/lang/example/my-app.ss:8-12`.

Consequently, brace continuation indentation remains unattested. The lexer currently classifies `(`, `[`, and `{` identically at `fixw-gerbil/private/lexer.ss:305-310`, while only brackets receive a dedicated formatter heuristic.

### 9. Suffix keywords and Gerbil-specific atoms

The corpus contains 6,040 ordinary atoms ending in `:` on 5,270 lines; 3,534 of those lines change.

Most frequent suffix keywords include:

- `effect:` — 1,280
- `unchecked:` — 362
- `help:` — 269
- `final:` — 250
- `constructor:` — 96
- `transparent:` — 84

Of 555 forms containing two or more direct suffix-keyword labels over multiple lines, 507 (91.4%) place every label in one column. Vertical label alignment usually survives; padding between labels and values does not.

Examples:

- formal labels: `gerbil/src/std/vector/vector.ss:32-35`;
- aligned label/value columns: `gerbil/src/std/serde/deserialize.ss:542-547`;
- `final:` table label: `gerbil/src/gerbil/compiler/optimize-top.ss:22-37`.

The lexer recognizes only `#:...` as keyword syntax at `fixw-gerbil/private/lexer.ss:312-318`; ordinary suffix keywords fall through as symbols at lines 321-326. Token spelling is retained, but a suffix keyword in head position can consequently select procedure-style rather than data-style indentation.

Gerbil-specific `%#`, `::`, `:::`, `@...`, dotted/rest, and ellipsis atoms remain indivisible. Their common changes are enclosing indentation and lost table spacing, not lexical splitting.

## Highest-frequency diff causes

Most frequent leading-only character-count deltas:

| Delta | Lines | Typical cause |
|---:|---:|---|
| `+1` | 11,984 | One-column clauses/data changed to structural two-column indentation |
| `+2` | 3,563 | Nested body/frame shifts |
| `-6` | 1,943 | Column-eight import/export anchors changed to column two |
| `+3` | 1,385 | Inherited nested-frame changes |
| `-2` | 845 | Generic argument realignment |
| `+7` | 774 | Tabs or long-head alignment |
| `+10` | 739 | Tabs or long-head alignment |
| `-3` | 584 | Generic argument realignment |
| `+4` | 547 | Notably `def*` clauses moving from column two to six |
| `-1` | 544 | Local one-column normalization |

### Review findings

- **High:** `fixw-gerbil/private/rules.ss:11-14` and `private/formatter.ss:50-55,80` erase dominant first-argument anchors.
- **High:** absent `cond` handling changes the corpus’s overwhelmingly one-column clauses.
- **High:** absent `def*` and `defcompile-method` handling creates extreme long-head alignment.
- **High:** `private/formatter.ss:104-116` removes deliberate intra-line columns on at least 3,704 lines.
- **Medium:** symbol-headed formal/data lists remain contextually ambiguous.
- **Medium:** suffix keywords are lexed as symbols rather than keywords.
- **Low/unresolved:** no multiline brace example supports a continuation policy.

## Confidence and exceptions

- **High confidence:** corpus selection, shared commit, file and line totals, line-diff categories, leading deltas, tab counts, and cited paired examples.
- **Medium-high confidence:** import/export, typed-formal, binding-list, definition, and clause-form structural totals.
- **Medium confidence:** semantic categorization of every mixed macro/template case because the classifier is a tolerant delimiter tree, not the Gerbil expander.
- **Low confidence:** any multiline-brace convention.

Important exceptions:

- Both attached-first and head-only imports are established.
- `export` is more heterogeneous because exports are often grouped per line.
- Too few active multiline `declare` forms exist for a strong conclusion.
- Tabs inflate some apparent column deltas.
- Corpus frequency establishes practice, not validity or a normative standard.
- The formatted tree is temporary evidence tied to one pinned commit.

## Reproducible read-only commands

### Provenance and inventory

```sh
cd /home/jay/Code/workbench-gerbil

git -C gerbil rev-parse HEAD
git -C /tmp/gerbil-fixw-run-CW0cop/gerbil rev-parse HEAD

find gerbil/src/{gerbil,std,lang,tools,tutorial} \
  -type f -name '*.ss' | sort | wc -l

git -C gerbil status --porcelain --untracked-files=no -- \
  src/gerbil src/std src/lang src/tools src/tutorial
```

Expected commit: `4a4d1a3059824adf6319105bde496bef00d09834`; expected file count: 483.

### Headline line-diff census

```sh
python3 - <<'PY'
from pathlib import Path
from collections import Counter

A = Path("/home/jay/Code/workbench-gerbil/gerbil/src")
B = Path("/tmp/gerbil-fixw-run-CW0cop/gerbil/src")
roots = ["gerbil", "std", "lang", "tools", "tutorial"]
stats = Counter()
byroot = Counter()
changed_files = 0

for root in roots:
    for p in sorted((A / root).rglob("*.ss")):
        rel = p.relative_to(A)
        a = p.read_text().splitlines(keepends=True)
        b = (B / rel).read_text().splitlines(keepends=True)
        assert len(a) == len(b), rel
        file_changed = False

        for x, y in zip(a, b):
            if x == y:
                stats["unchanged"] += 1
                continue
            file_changed = True
            stats["changed"] += 1
            byroot[root] += 1
            x = x.rstrip("\r\n")
            y = y.rstrip("\r\n")
            lx = len(x) - len(x.lstrip(" \t"))
            ly = len(y) - len(y.lstrip(" \t"))
            if x.lstrip(" \t") == y.lstrip(" \t"):
                stats["leading-only"] += 1
            elif lx == ly:
                stats["intraline-only"] += 1
            else:
                stats["leading+intraline"] += 1

        changed_files += file_changed

print("files", sum(1 for r in roots for _ in (A/r).rglob("*.ss")))
print("changed_files", changed_files)
print(stats)
print(byroot)
PY
```

Expected headline result: 483 files, 417 changed files, 32,521 changed lines.

### Intra-line spacing census

```sh
python3 - <<'PY'
from pathlib import Path
from collections import Counter
import re

A = Path("/home/jay/Code/workbench-gerbil/gerbil/src")
B = Path("/tmp/gerbil-fixw-run-CW0cop/gerbil/src")
roots = ["gerbil", "std", "lang", "tools", "tutorial"]
counts = Counter()
widths = Counter()

for root in roots:
    for p in (A/root).rglob("*.ss"):
        rel = p.relative_to(A)
        aa = p.read_text().splitlines()
        bb = (B/rel).read_text().splitlines()
        for a, b in zip(aa, bb):
            code = a.lstrip(" \t").split(";", 1)[0]
            runs = list(re.finditer(r"(?<=\S)([ \t]{2,})(?=\S)", code))
            if not runs:
                continue
            counts["lines"] += 1
            counts["runs"] += len(runs)
            counts["changed"] += a != b
            for run in runs:
                widths[len(run.group(1))] += 1

print(counts)
print(widths.most_common(20))
PY
```

Expected: 3,824 lines, 4,697 runs, 3,704 changed lines.

### Focused paired inspection

```sh
cd /home/jay/Code/workbench-gerbil

for file in \
  src/gerbil/compiler/base.ss \
  src/gerbil/runtime/util.ss \
  src/gerbil/main.ss \
  src/gerbil/compiler/optimize-top.ss \
  src/std/net/url.ss \
  src/std/serde/deserialize.ss \
  src/std/misc/process.ss
do
  diff -u "gerbil/$file" "/tmp/gerbil-fixw-run-CW0cop/gerbil/$file"
  rc=$?
  test "$rc" -le 1
done
```

`diff` status 1 means expected differences were found.

## Evidence-backed toolchain validation

Not run for this research-only report.

Focused package validation:

```sh
cd /home/jay/Code/workbench-gerbil/fixw-gerbil
export PATH=/opt/gerbil/bin:$PATH
unset GERBIL_PATH
gerbil build
gerbil test api-test.ss scanner-test.ss
```

Full package validation:

```sh
cd /home/jay/Code/workbench-gerbil/fixw-gerbil
export PATH=/opt/gerbil/bin:$PATH
unset GERBIL_PATH
gerbil build
gerbil test ./...
test -x .gerbil/bin/gerbil-fixw
```

Full pinned corpus validation, requiring a clean Gerbil checkout:

```sh
export GERBIL_SOURCE_ROOT=/path/to/clean/gerbil-at-4a4d1a3059824adf6319105bde496bef00d09834
cd /home/jay/Code/workbench-gerbil/fixw-gerbil
./validation/gerbil-corpus.sh
```

The corpus harness checks formatting, idempotence, reader equivalence, and `#lang` passthrough/EOF behavior at `fixw-gerbil/validation/gerbil-corpus.sh:9-48`. The current local source checkout does not satisfy its all-files-clean prerequisite because of unrelated untracked generated test artifacts.