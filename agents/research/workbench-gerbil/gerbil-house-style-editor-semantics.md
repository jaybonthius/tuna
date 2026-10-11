# Gerbil house-style editor indentation semantics

## Concise answer

Gerbil has no formal formatting specification; it documents two-space indentation and following surrounding code. The strongest editor authority is therefore the shipped `gerbil-mode.el`, which delegates indentation to Emacs `scheme-mode`.

Numeric `scheme-indent-function` values are **not** equivalent to fixw’s current “after N arguments, indent two spaces” rule:

- Emacs scans complete direct child sexps before the indentation point.
- It combines the remaining distinguished-argument count with a context-sensitive generic alignment column.
- The result depends on whether arguments began on the head line or a later line.
- `defun` is a distinct rule, not numeric `1`.
- Unknown calls, data lists, non-symbol heads, and nested clauses use generic alignment behavior that fixw does not consistently reproduce.

A small native deterministic implementation is feasible and preferable to requiring Emacs at runtime. Batch Emacs is valuable as a pinned golden-test oracle, provided exact source files are loaded, `-Q` is used, and `indent-tabs-mode` is disabled.

Confidence: **high** for the checked-in Emacs/Gerbil behavior and observed fixw deltas; **medium-high** for calling it canonical “house style,” because Gerbil explicitly has no formal style guide.

## Provenance

Inspected revisions:

- Emacs checkout `/home/jay/Code/emacs`: `541f693ca2e8de166cfe52c39bbfc497142215e9`
- Gerbil checkout `/home/jay/Code/workbench-gerbil/gerbil`: `4a4d1a3059824adf6319105bde496bef00d09834`
- fixw checkout `/home/jay/Code/workbench-gerbil/fixw-gerbil`: `f32d0fd359338e18722ad74f976eb91c3f469b9c`
- Batch executable: GNU Emacs 30.2, explicitly reloading the inspected Emacs and Gerbil source definitions.

## Authoritative editor path

Gerbil says only that code generally uses two spaces and that no formal style guide exists:

- `gerbil/CONTRIBUTING.md:191-195`

The Gerbil guide identifies the shipped mode as the mode providing Gerbil indentation:

- `gerbil/doc/guide/emacs.md:1-14`

`gerbil-mode` is directly derived from `scheme-mode` and runs `gerbil-init`, which installs global symbol properties:

- `gerbil/etc/gerbil-mode.el:232-242`
- `gerbil/etc/gerbil-mode.el:543-553`

`scheme-mode` installs:

- Scheme’s syntax table, including balanced `[]` and `{}`: `/home/jay/Code/emacs/lisp/progmodes/scheme.el:55-112`
- `lisp-indent-line` as the line indenter: `/home/jay/Code/emacs/lisp/progmodes/scheme.el:173-185`
- `scheme-indent-function` as `lisp-indent-function`: `/home/jay/Code/emacs/lisp/progmodes/scheme.el:193-198`

## Effective symbol properties

### Gerbil overrides

`gerbil-mode.el` assigns:

- Numeric `0`: `import`, `export`, `declare`, `include`, `or`, `and`, `case-lambda`, `call/cc`, `begin-syntax`, `cond-expand`, folds/maps, and related forms: `gerbil/etc/gerbil-mode.el:242-254`
- Numeric `1`: `if`, `when`, `unless`, binding forms, `match`, `for`, tests, interfaces, and related forms: `gerbil/etc/gerbil-mode.el:256-297`
- Numeric `2`: syntax/AST case forms, `do-while`, and `for/fold`: `gerbil/etc/gerbil-mode.el:298-302`
- `defun`: `def`, `defvalues`, `defsyntax`, definition/type/interface/locking forms, etc.: `gerbil/etc/gerbil-mode.el:303-317`

`interface` appears in both the `1` and `defun` groups; the later `defun` assignment wins.

### Inherited Scheme properties

The inherited standard Scheme rules are defined at:

- `/home/jay/Code/emacs/lisp/progmodes/scheme.el:647-676`
- `/home/jay/Code/emacs/lisp/progmodes/scheme.el:678-707`

Notable effective values include:

- `begin`, `delay`, `sequence`, `match-lambda`, `match-lambda*`: `0`
- `lambda`, `case`, `let*`, `letrec`, `with-syntax`, `when`, `unless`, `parameterize`, `match`: `1`
- `do`, `syntax-case`, `receive`, `let-optionals`, `let-optionals*`: `2`
- `dynamic-wind`: `3`
- `syntax-rules`: `defun`
- `let` and `match-let`: the function `scheme-let-indent`

Several DSSSL properties are also installed globally, including `λ = 1`:

- `/home/jay/Code/emacs/lisp/progmodes/scheme.el:522-528`

Important absences:

- `define` has no `scheme-indent-function` property.
- `define-syntax` has no such property.
- `deflogger` and other unlisted `def...` names have no property.
- `cond` has no Scheme editor indentation property.
- Any propertyless operator longer than three characters beginning with `def` is nevertheless treated as `defun`: `/home/jay/Code/emacs/lisp/progmodes/scheme.el:594-603`

An exact batch property inspection produced:

```text
import=0
if=1
syntax-case=2
def=defun
interface=defun
define=nil
define-syntax=nil
syntax-rules=defun
deflogger=nil
let=scheme-let-indent
cond=nil
lambda=1
match=1
λ=1
element=1
```

This means fixw’s declarations for `define`, `define-syntax`, and `syntax-rules` as numeric `1` are not faithful representations of the editor metadata.

## Exact numeric-rule semantics

The dispatch is in:

- `/home/jay/Code/emacs/lisp/progmodes/scheme.el:562-605`

The numeric implementation is inherited from:

- `/home/jay/Code/emacs/lisp/emacs-lisp/lisp-mode.el:1303-1346`

Although Scheme’s summary describes the first `N` “lines” as distinguished, the implementation actually scans complete direct child sexps and decrements `count` for each one encountered before the indentation point:

- `/home/jay/Code/emacs/lisp/emacs-lisp/lisp-mode.el:1315-1325`

With the default `lisp-body-indent = 2`:

1. It records the containing opener column and defines body indentation as opener column plus two: `lisp-mode.el:1312-1316`.
2. If the current child is still among the distinguished `N` operands:
   - the first or second distinguished child uses opener plus four;
   - later distinguished children use generic `normal-indent`: `lisp-mode.el:1327-1338`.
3. Once past the distinguished children:
   - the first body child commonly uses opener plus two;
   - otherwise it can retain generic alignment under the existing first argument: `lisp-mode.el:1339-1346`.

`normal-indent` is computed before special-form handling from the existing structural layout. Consequently, equal child ordinals do not guarantee equal indentation.

### Numeric `0`: imports and sequence-like forms

Canonical cases:

```scheme
(import :a
        :b)
```

The first import is on the head line, so later imports use generic alignment under `:a`, column eight.

```scheme
(import
  :a
  :b)
```

No argument begins on the head line, so the first body element uses opener plus two; later elements retain that column.

Gerbil documentation and source consistently show the first form:

- `gerbil/doc/guide/getting-started.md:273-278`
- `gerbil/src/tutorial/advanced-ensemble/rlb/rlb.ss:1-8`
- `gerbil/doc/reference/dev/test.md:48-51`

Thus numeric `0` does **not** mean “always indent every import by two.”

### Positive numeric rules

For numeric `1`:

```scheme
(if
    test
  then
  else)
```

`test` is the first distinguished operand and receives opener plus four. Body forms receive opener plus two.

When the distinguished operand is on the head line:

```scheme
(if test
  then
  else)
```

the body normally uses opener plus two.

If both the distinguished operand and another form are on the head line:

```scheme
(if test then
    else)
```

the later line falls back to generic alignment under `test`, not opener plus two.

Numeric `2` behaves similarly:

```scheme
(syntax-case
    stx
    ()
  pattern
  body)
```

Both distinguished operands are at plus four; body forms are at plus two.

This context sensitivity is why a flat “N arguments, then body” rule cannot reproduce the editor exactly.

### `scheme-let-indent`

`let` is not numeric `1`. It checks the first token after `let`:

- symbol-like first token, as in named `let`: invoke numeric `2`
- otherwise: invoke numeric `1`

Evidence:

- `/home/jay/Code/emacs/lisp/progmodes/scheme.el:627-631`

A faithful rule representation therefore needs at least integer, `defun`, and function/custom variants.

## `defun` semantics and definitions

`lisp-indent-defform` is separate from the numeric implementation:

- `/home/jay/Code/emacs/lisp/emacs-lisp/lisp-mode.el:1348-1354`

For a line after the form’s opening line, it returns opener plus `lisp-body-indent`, normally two. Hence:

```scheme
(def (f x)
  body1
  body2)

(def
  (f x)
  body)
```

Both the signature and body lines use two columns when they begin on later physical lines.

The outer `defun` rule does not govern the internals of a signature list. The signature is an ordinary nested list:

```scheme
(def (long-name alpha
                beta)
  body)

(def (long-name
      alpha
      beta)
  body)
```

In the first form, later formals align under the first formal. In the second, no formal appeared on the signature’s opening line, so generic Scheme indentation puts them one column after the signature opener, aligned with `long-name`.

Gerbil’s normal two-space definition bodies are visible throughout:

- `gerbil/doc/guide/getting-started.md:266-268`
- `gerbil/doc/guide/getting-started.md:280-285`
- `gerbil/src/tutorial/advanced-ensemble/rlb/rlb.ss:13-34`

`gerbil/doc/reference/dev/test.md:45-46` contains one inconsistent one-space body example, but surrounding definitions in the same document use two spaces at lines 53-62.

## Nested clauses and generic calls

When a containing form’s car is not a symbol, Scheme mode aligns under the containing list or an existing complete sexp:

- `/home/jay/Code/emacs/lisp/progmodes/scheme.el:575-590`

Observed editor result:

```scheme
(match value
  ([a b]
   (foo a)
   (bar b))
  (else
   (nope)))
```

`match = 1` puts clauses at parent plus two. Within a clause:

- A list/pattern car such as `[a b]` is non-symbol data; later forms align with it.
- `else` has no special property, so with no argument on its opening line its body uses generic opener-plus-one indentation.

Gerbil corpus examples use this clause style:

- `gerbil/src/misc/scripts/docstub.ss:8-12`
- `gerbil/src/v0.19-WIP/v0.19-TODIE-std/amb-test.ss:14-18`
- `gerbil/src/gerbil/runtime/hash.ss:552-558`

`cond` itself has no editor property. It therefore uses generic indentation:

```scheme
(cond
 ((p x)
  (foo x))
 (else
  (nope)))
```

The Gambit pretty-printer has a `cond` head format, but that is separate from Emacs editor indentation.

## Data lists

Scheme’s syntax table balances parentheses, brackets, and braces for editing:

- `/home/jay/Code/emacs/lisp/progmodes/scheme.el:85-100`

For lists whose car is another list rather than an operator symbol, siblings align with the first datum:

```scheme
((a b)
 (c d)
 ((e) f))

'((a b)
  (c d)
  ((e) f))
```

The quote prefix shifts the nested list opener one column, so its data align at column two rather than one. Bracket data behaves analogously:

```scheme
[a
 b
 [c
  d]]
```

For an unknown symbol-headed call:

```scheme
(function alpha
          beta)

(function
 alpha
 beta)
```

Arguments align under the first same-line argument when one exists; otherwise they use opener plus one. This generic opener-plus-one behavior is a major fixw mismatch.

## Why current fixw differs

**High — flattened rule kinds:** `fixw-gerbil/private/rules.ss:4-39` converts every Gerbil `defun` declaration into numeric `1` and also introduces numeric `1` entries for `define`, `define-syntax`, and `syntax-rules`. It cannot represent Emacs’s `defun`, implicit `def...`, or `scheme-let-indent` behavior.

**High — different integer contract:** fixw considers a numeric rule hit whenever the frame’s argument counter is greater than the stored value:

- `fixw-gerbil/private/formatter.ss:50-55`

Every hit returns opener plus two:

- `fixw-gerbil/private/formatter.ss:79-83`

This loses Emacs’s distinguished-operand plus-four behavior and its context-sensitive fallback to generic alignment.

**High — generic second-item rule:** fixw normally indents a second item by opener plus two:

- `fixw-gerbil/private/formatter.ss:71-78`

Scheme mode’s propertyless form with no item on the opening line uses opener plus one. This affects multiline formal lists, unknown calls, `cond`, and `else` clauses.

**Medium — saved alignment is overridden too early:** fixw records token columns and can reuse `last-indent`:

- `fixw-gerbil/private/formatter.ss:85-95`

But numeric rule hits take precedence. Thus `(import :a\n:b)` is forced to two spaces rather than aligning under `:a`.

**Medium — tests freeze the flattened interpretation:** the API test asserts a 122-entry literal and expects every rule’s “body” at two spaces:

- `fixw-gerbil/api-test.ss:37-61`

That test checks consistency with fixw’s current abstraction, not parity with `scheme-indent-function`.

Observed deltas:

| Input shape | Emacs/Gerbil mode | Current fixw |
|---|---:|---:|
| `(import :a` then next import | align at column 8 | column 2 |
| `(if` then test on next line | test at column 4 | column 2 |
| `(if test then` then else | align at column 4 | column 2 |
| signature with no formal on first line | opener + 1 | opener + 2 |
| `(else` then body | opener + 1 | opener + 2 |
| propertyless `cond` clauses | outer opener + 1 | outer opener + 2 |

Common `(def (f x)\nbody)` and `(if test\nthen)` happen to agree, which masks the semantic mismatch.

## Gambit/Gerbil pretty-printer evidence

Gerbil’s syntax printer converts syntax to a datum and calls `pp`:

- `gerbil/src/gerbil/runtime/syntax.ss:282-286`

Gerbil starts from Gambit’s standard readtable, modifying extended read macros, brackets, braces, and sharp-bang handling but not the pretty-print head table:

- `gerbil/src/gerbil/runtime/syntax.ss:288-310`
- `gerbil/src/gambit/lib/_io.scm:15775-15792`

The standard pretty-print table contains Scheme heads including `lambda`, `if`, `cond`, `case`, `let`, `define`, and `declare`, but not Gerbil’s `import`, `export`, `def`, or broader macro vocabulary:

- `gerbil/src/gambit/lib/_io.scm:12365-12394`

The printer:

- selects a vector format from the head table, or falls back based partly on head length: `gerbil/src/gambit/lib/_io.scm:11142-11165`
- uses vector fields to determine inline elements, line breaks, nested pair treatment, and indentation: `gerbil/src/gambit/lib/_io.scm:11167-11215`
- first attempts to fit the complete object on one line according to output width: `gerbil/src/gambit/lib/_io.scm:11278-11330`

Therefore Gambit `pretty-print` is a width-driven runtime datum serializer, not the source editor’s indentation oracle. It does not retain source line breaks or comments and its head vocabulary materially differs from `gerbil-mode`.

## Batch Emacs as an oracle

### Assessment

Batch Emacs is useful as an **attested golden-output oracle**, not an attractive runtime formatter dependency.

Advantages:

- Executes the exact editor implementation.
- Requires no GUI.
- Can verify nuanced cases that are easy to misread from `lisp-indent-specform`.
- Good for fixture generation and differential tests.

Constraints:

- `-Q` is required to exclude user property mutations and hooks.
- The exact inspected `lisp-mode.el`, `scheme.el`, and `gerbil-mode.el` must be loaded; otherwise system Emacs version changes behavior.
- `indent-tabs-mode` must be set to `nil`; otherwise column-eight imports may be emitted with tabs.
- `indent-region` operates sequentially, so later lines observe indentation already applied to earlier lines.
- Symbol properties are global within the Emacs process; isolated batch invocations avoid contamination.
- Emacs indentation does not normalize same-line token spacing and is not a complete source formatter.
- Malformed syntax, reader extensions, comments, and future Emacs parser changes remain version-sensitive.

### Reproducible command shape

```sh
emacs -Q --batch --eval '
(progn
  (load-file "/home/jay/Code/emacs/lisp/emacs-lisp/lisp-mode.el")
  (load-file "/home/jay/Code/emacs/lisp/progmodes/scheme.el")
  (load-file "/home/jay/Code/workbench-gerbil/gerbil/etc/gerbil-mode.el")
  (with-temp-buffer
    (insert "(import :a\n:b)\n")
    (gerbil-mode)
    (setq-local indent-tabs-mode nil)
    (indent-region (point-min) (point-max))
    (princ (buffer-string))))'
```

Expected output:

```scheme
(import :a
        :b)
```

## Can it be reproduced without Emacs?

Yes. For valid fixw input, a deterministic native implementation needs only the existing token/CST structure plus richer rule kinds and line-aware sibling scanning:

1. Find the innermost containing list and its opener column.
2. Determine whether its car is a symbol.
3. Compute generic alignment:
   - align under an existing first same-line argument;
   - otherwise use opener plus one;
   - for non-symbol heads, align under the relevant complete first sexp.
4. Resolve the effective rule:
   - integer;
   - `defun`;
   - custom `let` behavior;
   - absent, including the implicit `def...` heuristic.
5. For integer rules, count complete direct children before the indentation point and reproduce `lisp-indent-specform`’s distinguished/body branches.
6. Apply lines sequentially so later alignment columns reflect earlier output.

The numeric/`defun` core is small. Exact parity on malformed input is less small because Emacs derives state from its syntax table and partial-sexp parser. A native implementation can remain deterministic while explicitly choosing conservative recovery behavior rather than embedding Emacs.

## Materially different implementation options

### Option A — Native editor-parity rule engine

Represent integer, `defun`, and custom rules distinctly and reproduce `normal-indent`, direct-child counting, and generic call/data alignment.

- Closest runtime behavior to the shipped editor.
- No external dependency.
- Must define recovery behavior where fixw’s tolerant CST and Emacs partial parsing disagree.

### Option B — Batch Emacs runtime oracle

Pipe source through a pinned batch Emacs invocation.

- Highest fidelity to that exact Emacs checkout.
- Slow startup, large dependency, version/platform variability, tab/config hazards.
- Does not provide fixw’s same-line spacing normalization by itself.

### Option C — Native formatter with batch differential fixtures

Keep the native formatter and use pinned batch Emacs only to generate or verify a matrix of imports, numeric forms, definitions, formal lists, clauses, calls, and data.

- Avoids production dependency while guarding semantic parity.
- Fixtures must pin Emacs/Gerbil revisions and intentionally document malformed-input exceptions.

### Option D — Explicit Gerbil corpus style rather than editor parity

Define simpler stable rules from current Gerbil source examples, such as aligned imports and two-space bodies, without claiming exact `scheme-mode` equivalence.

- Simpler and stable across Emacs changes.
- Requires acknowledging deliberate differences for obscure layouts, `let`, implicit `def...`, and generic calls.

## Residual risks and unresolved gaps

- **High:** Gerbil explicitly has no formal style specification; editor behavior is strong convention, not a language standard.
- **High:** Emacs numeric behavior depends on physical line placement and generic alignment, not only AST child ordinal.
- **High:** fixw’s current tests codify the flattened interpretation and do not attest editor parity.
- **Medium:** `scheme-let-indent`, implicit propertyless `def...`, and deprecated `scheme-indent-hook` expand the effective rule system beyond a numeric table.
- **Medium:** malformed input can produce different structural state in fixw’s tolerant parser and Emacs `parse-partial-sexp`.
- **Medium:** editor properties are global and user-extensible; only `emacs -Q` gives a reproducible baseline.
- **Medium:** default Emacs indentation may emit tabs unless explicitly disabled.
- **Medium:** Gambit pretty-print formats are separate width-driven semantics and should not be merged mechanically with editor rules.
- **Low:** documentation contains at least one inconsistent one-space definition body example.
- **Low:** future Emacs changes can alter behavior even if `gerbil-mode.el` remains unchanged.

## Validation commands

### Focused editor differential

Use the batch command above against a fixture matrix and compare it with:

```sh
cd /home/jay/Code/workbench-gerbil
printf '%b' '(import :a\n:b)\n' |
  fixw-gerbil/.gerbil/bin/gerbil-fixw
```

### Focused fixw tests

```sh
cd /home/jay/Code/workbench-gerbil/fixw-gerbil
export PATH=/opt/gerbil/bin:$PATH
unset GERBIL_PATH
gerbil test api-test.ss
```

### Full fixw validation

```sh
cd /home/jay/Code/workbench-gerbil/fixw-gerbil
export PATH=/opt/gerbil/bin:$PATH
unset GERBIL_PATH
gerbil build
gerbil test ./...
```

These commands are documented at `fixw-gerbil/README.md:5-14`; build contents are defined at `fixw-gerbil/build.ss:1-10`.

### Full Gerbil validation

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make check
```

or:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
./build.sh env gerbil test ./...
```

Evidence: `gerbil/CONTRIBUTING.md:176-189`.