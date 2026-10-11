# Gerbil v19 dev31 hermetic runtime matrix

## Conclusion

**Blocker:** the current checklist template is not fully hermetic. `GERBIL_PATH` isolates the writable workspace, but:

1. package-qualified source imports require an explicit `GERBIL_LOADPATH` containing the fixture source root;
2. executables must run with the same mode-specific `GERBIL_PATH` and controlled `GERBIL_LOADPATH` used for compilation;
3. invoking executables without a sanitized environment inherits ambient loader variables;
4. the attested Gerbil checkout/version pair must be checked before creating or compiling the fixture.

The corrected commands below address these issues. They were derived from Gerbil v0.19-dev-31 source and documentation, but this read-only research run did not create or execute the disposable fixture.

## Exact environment semantics

### `GERBIL_PATH`

- It is the root of Gerbil’s writable workspace.
- If unset, it becomes `~/.gerbil`.
- At normal runtime initialization, its `lib` directory precedes the installed Gerbil library:
  ```
  $GERBIL_PATH/lib
  $GERBIL_HOME/lib
  ```
- `gxc` defaults its output directory to `$GERBIL_PATH/lib`; `-d` overrides that output location.
- Therefore, explicitly setting `GERBIL_PATH` prevents fallback to `~/.gerbil`. Merely supplying `-d` does **not** prevent the runtime from using an unset `GERBIL_PATH`.

Evidence:

- `gerbil/src/gerbil/runtime/system.ss:52-59`
- `gerbil/src/gerbil/runtime/init.ss:207-230`
- `gerbil/src/gerbil/gxc-main.ss:31-50`
- `gerbil/doc/guide/env-vars.md:6-18`
- `gerbil/doc/reference/dev/build.md:128-148`

### `GERBIL_LOADPATH`

- It is colon-separated.
- Empty components are discarded.
- In dev31 source, its entries are **prepended**, in supplied order, before `$GERBIL_PATH/lib` and the installed library.
- The guide says “appended,” but `runtime/init.ss` is authoritative for this attested version and performs:
  ```scheme
  (append parsed-GERBIL_LOADPATH default-load-path)
  ```
- Set it explicitly rather than inheriting it. A fixture source root should be the sole entry for these probes.

Resulting controlled load path:

```
$fixture/src
$run_root/$mode/env/lib
/opt/gerbil/current/lib
```

The installed library remains an intentional, attested system dependency. The commands preflight that the fixture’s unique package does not already exist there.

Evidence:

- `gerbil/src/gerbil/runtime/init.ss:219-230`
- `gerbil/doc/guide/env-vars.md:20-25`
- `gerbil/doc/guide/intro.md:1196-1203`

### `gxi` package source imports

For `:workbench/emacsen/runtime/hermetic/kernel`, the expander:

1. removes the leading colon;
2. searches each runtime load-path directory;
3. recognizes compiled interface/source forms under the package-qualified path;
4. can resolve `.ss`, `.sld`, or `.scm` source when no suitable interface is used.

Thus, setting only:

```sh
GERBIL_PATH="$run_root/gxi/env"
```

does not make an independent fixture source tree searchable. Use:

```sh
GERBIL_LOADPATH="$fixture/src"
```

The fixture directory must mirror its package ID:

```
src/workbench/emacsen/runtime/hermetic/kernel.ss
```

Evidence:

- `gerbil/src/gerbil/expander/module.ss:407-445`
- `gerbil/doc/guide/intro.md:1186-1242`
- `gerbil/src/gerbil/gxi-main.ss:42-102`

### `gxc` compilation

`gxc` uses the same initialized load path while expanding imports. `-d` controls generated artifacts but is not a replacement for a source search path.

For hermetic compilation:

- set `GERBIL_PATH` to the mode’s fresh environment;
- set `GERBIL_LOADPATH` to the fixture source root;
- use `-d "$mode_env/lib"` on every invocation;
- compile all library units with the same optimization flags for that mode;
- use `-exe` and full-program optimization only on the final combination step.

The compiler’s static-module lookup also considers the runtime load path, current output directory, and the current `$GERBIL_PATH/lib`.

Evidence:

- `gerbil/src/gerbil/gxc-main.ss:31-50,177-206`
- `gerbil/src/gerbil/compiler/driver.ss:584-617`
- `gerbil/src/gerbil/gxc-main.ss:6-28`
- `gerbil/doc/guide/intro.md:1205-1242`

### Executable runtime loading

Ordinary dependencies linked into an executable are registered as built-in modules. Runtime imports not already built in use the runtime load path.

The native runtime loader searches each directory in order for:

1. the latest numbered compiled object, such as `.o1`, `.o2`, etc.;
2. generated `.scm`.

It does **not** directly load Gerbil `.ss` source. Runtime Gerbil source configuration therefore requires the expander and `read`/`eval` or an equivalent source-evaluation seam. Imports encountered by that expander then use the controlled load path above.

An absolute configuration filename is unaffected by `GERBIL_PATH`; imports inside it are affected.

Evidence:

- `gerbil/src/gerbil/runtime/loader.ss:14-29,31-65,99-125`
- `gerbil/src/gerbil/runtime/init.ss:247-258`
- `plans/emacsen-runtime/checklist.md`, M3 deployed evaluation requirements

## Current attestation and dirty state

Attested values observed:

```text
Gerbil checkout:
4a4d1a3059824adf6319105bde496bef00d09834

Installed runtime:
Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369
```

Dirty paths in the attested Gerbil checkout:

```text
 M src/gambit/lib/_kernel.c
 M src/gambit/lib/_module.c
 M src/gambit/lib/_num.c
```

These are unstaged modifications. They must be copied into every result record because they can affect runtime interpretation.

The enclosing workbench checkout was also dirty, with no staged files. Its state is unrelated to the attested Gerbil commit and must not replace the nested `gerbil` checkout attestation.

## Disposable package-qualified fixture

The following builder writes only beneath a disposable `/tmp` root, never beneath the checkout or playground:

```sh
set -eu

run_root=$(mktemp -d /tmp/workbench-gerbil-hermetic.XXXXXX)
trap 'rm -rf "$run_root"' EXIT HUP INT TERM
fixture="$run_root/fixture"
pkg=workbench/emacsen/runtime/hermetic
src="$fixture/src/$pkg"

mkdir -p "$src"

cat >"$src/kernel.ss" <<'EOF'
;;; -*- Gerbil -*-
package: workbench/emacsen/runtime/hermetic

(export config-value set-config!)

(def current-config 'initial)

(def (config-value)
  current-config)

(def (set-config! value)
  (set! current-config value))
EOF

cat >"$src/config.ss" <<'EOF'
;;; -*- Gerbil -*-
package: workbench/emacsen/runtime/hermetic

(import :workbench/emacsen/runtime/hermetic/kernel)

(set-config! 'configured)
EOF

cat >"$src/main.ss" <<'EOF'
;;; -*- Gerbil -*-
package: workbench/emacsen/runtime/hermetic

(import :gerbil/expander
        :workbench/emacsen/runtime/hermetic/kernel)
(export main)

(def (main . args)
  (displayln (config-value))
  (gerbil-load-expander!)
  (eval '(import :workbench/emacsen/runtime/hermetic/config))
  (displayln (config-value))
  (unless (eq? (config-value) 'configured)
    (error "runtime configuration did not update compiled module state"))
  (displayln "hermetic-ok"))
EOF
```

Expected output in every successful mode:

```text
initial
configured
hermetic-ok
```

This fixture proves:

- package-qualified `gxi` source resolution;
- separately compiled package placement;
- runtime source import through the expander;
- runtime configuration mutating state belonging to the executable’s compiled kernel module.

It is an environment/toolchain fixture, not the later M1–M3 behavior fixture.

## Fail-fast attestation and sanitized environment

Run this before fixture construction or compilation:

```sh
set -eu

expected_commit=4a4d1a3059824adf6319105bde496bef00d09834
expected_version='Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369'
gerbil_checkout=/home/jay/Code/workbench-gerbil/gerbil
gxi=/opt/gerbil/bin/gxi
gxc=/opt/gerbil/bin/gxc

actual_commit=$(git -C "$gerbil_checkout" rev-parse HEAD)
actual_version=$("$gxi" -v 2>&1)

if test "$actual_commit" != "$expected_commit"; then
  printf '%s\n' \
    "Gerbil checkout mismatch" \
    "expected: $expected_commit" \
    "actual:   $actual_commit" >&2
  exit 64
fi

if test "$actual_version" != "$expected_version"; then
  printf '%s\n' \
    "Installed Gerbil mismatch" \
    "expected: $expected_version" \
    "actual:   $actual_version" >&2
  exit 64
fi
```

After creating `run_root`, record provenance:

```sh
mkdir -p "$run_root/attestation"

printf '%s\n' "$actual_commit" \
  >"$run_root/attestation/gerbil-commit.txt"
printf '%s\n' "$actual_version" \
  >"$run_root/attestation/installed-version.txt"

git -C "$gerbil_checkout" status \
  --porcelain=v1 --untracked-files=all \
  >"$run_root/attestation/gerbil-dirty-paths.txt"

git -C "$gerbil_checkout" diff --name-only \
  >"$run_root/attestation/gerbil-unstaged-paths.txt"
git -C "$gerbil_checkout" diff --cached --name-only \
  >"$run_root/attestation/gerbil-staged-paths.txt"

test ! -s "$run_root/attestation/gerbil-staged-paths.txt" || {
  echo "Gerbil checkout has staged files; refusing attestation" >&2
  exit 65
}
```

## Hermetic matrix commands

These commands deliberately use `env -i` to remove ambient `HOME`, `GERBIL_LOADPATH`, `GAMBOPT`, compiler overrides, and unrelated environment state.

```sh
set -eu

pkg=workbench/emacsen/runtime/hermetic
src_root="$fixture/src"
kernel="$src_root/$pkg/kernel.ss"
main="$src_root/$pkg/main.ss"

for mode in gxi normal opt fpo; do
  mkdir -p \
    "$run_root/$mode/env/lib" \
    "$run_root/$mode/bin" \
    "$run_root/$mode/home" \
    "$run_root/$mode/tmp"
done

# Refuse an accidental fallback to a same-named installed fixture.
test ! -e "/opt/gerbil/current/lib/$pkg" || {
  echo "fixture package already exists in installed Gerbil library" >&2
  exit 66
}

mode_env() {
  mode=$1
  shift
  env -i \
    HOME="$run_root/$mode/home" \
    TMPDIR="$run_root/$mode/tmp" \
    PATH=/usr/bin:/bin \
    GERBIL_PATH="$run_root/$mode/env" \
    GERBIL_LOADPATH="$src_root" \
    "$@"
}

assert_output() {
  mode=$1
  shift
  output=$(mode_env "$mode" "$@")
  expected='initial
configured
hermetic-ok'
  if test "$output" != "$expected"; then
    printf 'unexpected %s output:\n%s\n' "$mode" "$output" >&2
    exit 67
  fi
  printf '%s\n' "$output"
}

# Development: package dependency must source-resolve from GERBIL_LOADPATH.
assert_output gxi /opt/gerbil/bin/gxi "$main"

# Normal production.
mode_env normal /opt/gerbil/bin/gxc \
  -d "$run_root/normal/env/lib" \
  "$kernel"
mode_env normal /opt/gerbil/bin/gxc \
  -d "$run_root/normal/env/lib" \
  -exe -o "$run_root/normal/bin/run" \
  "$main"
assert_output normal "$run_root/normal/bin/run"

# Optimized production: every compiled fixture unit receives -O.
mode_env opt /opt/gerbil/bin/gxc \
  -O -d "$run_root/opt/env/lib" \
  "$kernel"
mode_env opt /opt/gerbil/bin/gxc \
  -O -d "$run_root/opt/env/lib" \
  -exe -o "$run_root/opt/bin/run" \
  "$main"
assert_output opt "$run_root/opt/bin/run"

# Experimental full-program optimization.
mode_env fpo /opt/gerbil/bin/gxc \
  -O -d "$run_root/fpo/env/lib" \
  "$kernel"
mode_env fpo /opt/gerbil/bin/gxc \
  -O -full-program-optimization \
  -d "$run_root/fpo/env/lib" \
  -exe -o "$run_root/fpo/bin/run" \
  "$main"
assert_output fpo "$run_root/fpo/bin/run"
```

### Full-program retention characterization

If baseline full-program optimization removes definitions needed by runtime evaluation, repeat in a new environment, not the existing FPO environment:

```sh
mode=fpo-retained
mkdir -p \
  "$run_root/$mode/env/lib" \
  "$run_root/$mode/bin" \
  "$run_root/$mode/home" \
  "$run_root/$mode/tmp"

mode_env "$mode" /opt/gerbil/bin/gxc \
  -O -d "$run_root/$mode/env/lib" \
  "$kernel"

mode_env "$mode" /opt/gerbil/bin/gxc \
  -O -full-program-optimization \
  -prelude '(declare (not optimize-dead-definitions))' \
  -d "$run_root/$mode/env/lib" \
  -exe -o "$run_root/$mode/bin/run" \
  "$main"

assert_output "$mode" "$run_root/$mode/bin/run"
```

This remains experimental characterization and must not be reported as normal or `-O` production support.

## Validation levels

### Focused validation

Run attestation, fixture construction, and:

```sh
assert_output gxi /opt/gerbil/bin/gxi "$main"

mode_env normal /opt/gerbil/bin/gxc \
  -d "$run_root/normal/env/lib" "$kernel"
mode_env normal /opt/gerbil/bin/gxc \
  -d "$run_root/normal/env/lib" \
  -exe -o "$run_root/normal/bin/run" "$main"
assert_output normal "$run_root/normal/bin/run"
```

### Full validation

Run the complete gxi, normal, `-O`, and full-program matrix above, followed by:

```sh
find "$run_root" -type f -print | sort \
  >"$run_root/attestation/generated-files.txt"

# No generated compiler artifact may occur beneath either checkout.
test -z "$(git -C /home/jay/Code/workbench-gerbil status \
  --porcelain=v1 --untracked-files=all \
  | grep -E '\.(o[0-9]*|scm|ssi|ssxi|c|exe)$' || true)"
```

The final checkout-artifact check should be compared with a pre-run status snapshot because this repository already contains unrelated dirty and untracked paths.

## Required checklist correction

Replace the existing template’s environment handling as follows:

- add `GERBIL_LOADPATH="$fixture_source_root"` to `gxi`, every `gxc`, and every executable invocation;
- run each command through a sanitized `env -i` wrapper;
- give every mode separate `HOME`, `TMPDIR`, `GERBIL_PATH`, `env/lib`, and executable directories;
- attest the exact checkout commit and exact `gxi -v` string before compilation;
- record `git status --porcelain=v1 --untracked-files=all`;
- reject staged Gerbil-source changes;
- use a unique package-qualified fixture and reject an installed package collision.

## Risks and unresolved gaps

- **Blocker:** the disposable fixture and matrix were not executed by this read-only research worker.
- **High:** the guide’s “appended” description of `GERBIL_LOADPATH` conflicts with dev31 implementation, which prepends it.
- **High:** FPO can remove definitions reachable only through runtime evaluation; the retention retry must remain characterization.
- **Medium:** the installed Gerbil library cannot be removed from the runtime load path through these variables. It is controlled by exact version attestation and package-collision preflight.
- **Medium:** `env -i` intentionally removes locale and user settings. Add variables only when a fixture demonstrably requires them.
- **Confidence:** high for environment/load-path semantics; medium for the unexecuted runtime-evaluation fixture.

No playground application files were inspected or modified.