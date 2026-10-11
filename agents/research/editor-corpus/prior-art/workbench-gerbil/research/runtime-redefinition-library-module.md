# Runtime redefinition after moving `greeting` to `lib.ss`

## Concise answer

For the exact three-file design, **`(declare (separate))` is not required in any file** for either:

- interpreted source-module import through `gxi`; or
- normal separately compiled `gxc -exe`.

`main.ss` calls an imported global defined in another Gambit compilation unit, so Gambit cannot apply its `block` assumption that the definition is immutable. The ordinary call therefore dereferences `playground/lib#greeting` after the config’s `set!`.

If the declaration is retained defensively, it belongs **only in `playground/lib.ss`, before `greeting`’s definition**. It is unnecessary in `main.ss` and does not affect imported globals. It becomes semantically necessary if `lib.ss` itself contains ordinary calls to `greeting` that must observe external mutation.

## Minimal exact code

### `playground/lib.ss`

```scheme
namespace: playground/lib

(export greeting)

(def (greeting) "default")
```

### `playground/main.ss`

```scheme
namespace: playground/main

(import :gerbil/expander
        "lib")

(export main)

(def (main . args)
  (gerbil-load-expander!)
  (displayln (greeting))
  (eval '(include "playground/config.scm"))
  (displayln (greeting)))
```

### `playground/config.scm`

```scheme
(extern namespace: playground/lib
  greeting)

(set! greeting
  (lambda ()
    "configured"))
```

Expected stdout:

```text
default
configured
```

No setter, wrapper, parameter, or macro is involved.

### Conservative declaration variant

If preserving the explicit external-mutation contract against future same-module calls, place this in `lib.ss`, before `def`:

```scheme
(declare (separate))
```

Do not add it to `main.ss`.

## What `(declare (separate))` precisely means

Gambit declarations:

- are compiler directives;
- are ignored by the interpreter;
- are lexically scoped like macros.

Authoritative source: `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4886-4892`.

`(block)` lets Gambit assume that a global defined in the current compiled file, and not assigned in that file, will never be mutated. `(separate)` withholds that assumption:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4904-4910`
- `/home/jay/Code/gerbil/src/gambit/gsc/_ptree1.scm:418-422`

The optimizer concretely treats a single global definition as a permanent value only when the definition’s environment is `block`:

- `/home/jay/Code/gerbil/src/gambit/gsc/_ptree1.scm:323-331`.

This permits direct calls, constant propagation, and user-procedure inlining. Gambit documents that global procedure inlining requires the definition site to be `block`:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4921-4939`.

Consequently, `separate` may cost an extra global lookup and prevent inlining or related optimization at same-file references. It does **not** make the binding mutable—the binding is already assignable. It tells the compiler that mutation by other code must remain observable.

At Gerbil module scope, declarations are module-local and are not inherited by nested modules:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:698-704`.

Gerbil carries a source declaration into generated Gambit code:

- `/home/jay/Code/gerbil/src/gerbil/compiler/compile.ss:453-464`.

Although standalone Gambit defaults to `separate`, Gerbil prefixes generated module runtime files with `(block)`:

- Gambit default: `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:5145-5174`
- Gerbil generated default: `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:787-804`.

“Separate module compilation” in Gerbil executable documentation is a different concept: it describes compiling/linking modules as separate units rather than full-program optimization. It does not mean every generated module has an effective `(declare (separate))`:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1290-1317`.

## Exact placement finding

| Location | Needed for this design? | Reason |
|---|---:|---|
| `playground/lib.ss` | No, currently | It defines `greeting` but contains no runtime references to it. |
| `playground/main.ss` | No | `greeting` is external to main’s Gambit compilation unit; `block` only grants assumptions about globals defined in the current file. |
| `playground/config.scm` | No | It is interpreted at runtime; declarations are ignored by the interpreter. |

If `lib.ss` later calls its own `greeting`, put `(declare (separate))` before the definition. Placement merely before the call is insufficient because Gambit tests the declaration environment of the definition itself.

## Tested facts

Disposable fixtures were created only under `/tmp`.

### Declaration matrix

For source import and normal `gxc -exe`, all four variants passed:

| Declaration placement | `gxi` | normal `gxc -exe` |
|---|---|---|
| nowhere | `default`, `configured` | `default`, `configured` |
| `lib.ss` only | pass | pass |
| `main.ss` only | pass | pass |
| both | pass | pass |

Fixture: `/tmp/wbg-separate-matrix2.t8RP4j`.

The same matrix also passed separate-module `gxc -O` on installed Gerbil `v18.2-20260722T1909420700`.

A control fixture with `greeting` and its call sites in the **same module** demonstrated the distinction:

- without `separate`: compiled output was `default`, `default`;
- with `separate` before the definition: `default`, `configured`;
- interpreted execution produced `default`, `configured` in both cases.

Fixture: `/tmp/wbg-same-module.Bjjb7J`.

This confirms why the current two-file implementation needs the declaration while the proposed library/import split does not.

## Namespace and import resolution

The repository has no `gerbil.pkg`. Therefore the stable sibling file-module import is:

```scheme
(import "lib")
```

String module paths are the documented file-module syntax:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1098-1115`.

In the tested package-less fixture:

- `"lib"` resolved relative to `main.ss` and worked;
- `./lib` was interpreted as library-relative `:lib` and failed because no such library module existed;
- `"playground/lib"` from inside `playground/main.ss` duplicated the directory and failed.

The explicit `namespace: playground/lib` gives the mutable runtime binding the stable symbol `playground/lib#greeting`, independent of the file module’s dependency ID. Explicit namespaces are documented at:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1148-1167`.

`greeting` must be exported for ordinary import into `main.ss`. The config’s `extern` directly resolves the runtime binding and then `set!` compiles to Scheme assignment:

- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:195-213`
- `/home/jay/Code/gerbil/src/gerbil/runtime/eval.ss:429-444,488-510`.

The official runtime-eval guide uses the same main/library/config architecture and library namespace targeting:

- `/home/jay/Code/gerbil/doc/guide/eval.md:95-158`.

## Build-output consequence

Once `main.ss` imports `lib.ss`, this former one-command build is insufficient:

```sh
gxc -d "$tmpdir" -exe ... playground/main.ss
```

A tested fresh build failed with exit 70:

```text
cannot find static module
form: lib
detail: "lib.scm"
```

Compile `lib.ss` first into the same output directory. Gerbil searches the output directory’s `static/` subdirectory for executable dependencies:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:583-614`.

The library compilation creates `lib.ssi`, loader/runtime files, and `static/lib.scm`; executable compilation then consumes that static module. The official build-script example similarly orders the library before the executable:

- `/home/jay/Code/gerbil/doc/guide/eval.md:139-149`.

## Current repository behavior

Current `playground/main.ss` defines and calls `greeting` in one module, with `separate` before the definition:

- namespace/import/export: `playground/main.ss:1-5`
- declaration: `playground/main.ss:7`
- definition: `playground/main.ss:9`
- calls around runtime config: `playground/main.ss:11-15`.

Current config targets `playground/main`:

- `playground/config.scm:1-6`.

Both current source import and normal compiled execution were retested and produce the required output.

The prior owner-approved plan explicitly required the declaration for the same-module design and excluded `lib.ss`:

- `plans/emacs-like-runtime-redefinition/spec.md:28-48`
- `plans/emacs-like-runtime-redefinition/spec.md:70-78`.

Its compiled validation command at `plans/emacs-like-runtime-redefinition/spec.md:98-115` must be updated for the new library dependency.

## Validation commands after implementation

### Focused interpreted source-module import

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

printf 'default\nconfigured\n' >"$tmpdir/expected"
/opt/gerbil/bin/gxi \
  -e '(begin (import "playground/main") (main))' \
  >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

### Full normal compiled validation

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/build"

printf 'default\nconfigured\n' >"$tmpdir/expected"

/opt/gerbil/bin/gxc \
  -d "$tmpdir/build" \
  playground/lib.ss

/opt/gerbil/bin/gxc \
  -d "$tmpdir/build" \
  -exe \
  -o "$tmpdir/build/runtime-customization" \
  playground/main.ss

"$tmpdir/build/runtime-customization" >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

An identical two-stage build with `-O` on both compiler commands passed on the installed toolchain, but normal `gxc -exe` remains the focused acceptance boundary.

## Risks and unresolved boundaries

- **High — full-program optimization:** `-O -full-program-optimization` built but failed at runtime while loading the expander with unbound `__eval-import`, for every declaration placement. FPO is unsupported for this example on the installed snapshot.
- **Medium — future same-module calls:** If `lib.ss` gains calls to its own mutable `greeting`, add `(declare (separate))` before the definition or those calls may retain the original procedure.
- **Medium — optimizer portability:** Separate-module `-O` passed, but config-only mutation remains invisible to Gerbil’s source optimizer. This is tested behavior for the installed snapshot, not a cross-version optimization guarantee.
- **Medium — trusted evaluation:** `eval` and `extern` bypass export-boundary safety; config must remain trusted.
- **Low — working directory:** `include "playground/config.scm"` is process-working-directory-relative. Run from repository root.
- **Low — package migration:** Adding a `gerbil.pkg` may make `./lib` appropriate, but the present package-less layout requires `"lib"`.
- **Confidence:** High for normal `gxi` and `gxc -exe`, declaration scope, placement, namespace target, and build ordering; medium for behavior across future optimized Gerbil releases.