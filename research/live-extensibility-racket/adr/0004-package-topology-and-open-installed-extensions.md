# ADR 0004: Package topology and open installed extensions

Status: accepted; exact Datastar checksum-install portions superseded by ADR 0005

## Context

Tuna configuration must import deliberately and independently installed compiled values and transformers through the Racket installation's collection resolver. Core must remain host-neutral and must not depend on counter, dummy, or message policy. Assets and the launcher must work outside the source-tree current working directory. A finite standalone executable cannot preserve open import of future installed extensions.

This ADR fixes the pre-source Racket CS 9.2 metadata, launcher, dependency, resource, and validation contract. Factual direct-import exhaustiveness is checked before writing final metadata; it is not deferred as a future architecture decision.

## Decision

### Four single-collection packages

The repository has exactly four installable single-collection package/collection pairs:

| Package/root | Exact root `#lang info` collection | Public role |
|---|---|---|
| `tuna` / `packages/tuna/` | `(define collection "tuna")` | Core public/private modules, exact assets, and `tuna` launcher |
| `tuna-example-counter` / `packages/tuna-example-counter/` | `(define collection "tuna-example-counter")` | Counter root and renderer example policy |
| `tuna-example-dummy` / `packages/tuna-example-dummy/` | `(define collection "tuna-example-dummy")` | Independently compiled/open-extension and once-only initialization proof |
| `tuna-example-message` / `packages/tuna-example-message/` | `(define collection "tuna-example-message")` | Same-name callable/value, automatic-local, host-neutral action example |

Each package root has one `#lang info` file. String collection names deliberately fix collection identity independently of package-source naming; none uses `'multi` or `'use-pkg-name`.

The public core module direction is `tuna/...`; each example exposes only its approved collection module. Every example package depends on package name `"tuna"`. `tuna` does not depend on any example package, and examples do not become transitive core policy. The message example remains outside core even though its Gerbil predecessor lived under `lib`.

### Exact metadata contract

Before creating metadata, review every implemented module's direct imports and map each imported collection to its providing package. The approved baseline is exact unless that factual review finds an additional **direct** dependency:

```racket
;; packages/tuna/info.rkt
#lang info
(define collection "tuna")
(define deps
  '(("base" #:version "9.2")
    ("datastar-lib" #:version "0.4")
    ("web-server-lib" #:version "1.13")
    "net-lib"))
(define build-deps '("rackunit-lib" "crypto-lib"))

(define racket-launcher-names '("tuna"))
(define racket-launcher-libraries '("main.rkt"))
```

```racket
;; packages/tuna-example-counter/info.rkt
#lang info
(define collection "tuna-example-counter")
(define deps '(("base" #:version "9.2") "tuna"))
(define build-deps '("rackunit-lib"))
```

```racket
;; packages/tuna-example-dummy/info.rkt
#lang info
(define collection "tuna-example-dummy")
(define deps '(("base" #:version "9.2") "tuna"))
(define build-deps '("rackunit-lib"))
```

```racket
;; packages/tuna-example-message/info.rkt
#lang info
(define collection "tuna-example-message")
(define deps '(("base" #:version "9.2") "tuna"))
(define build-deps '("rackunit-lib"))
```

`rackunit-lib` remains in each example's `build-deps` because the approved package topology includes RackUnit tests. Tuna also uses `crypto-lib` in its package tests. No example appears in Tuna's `deps` or `build-deps`. No Tuna version floor is invented before Tuna itself declares a package version.

Only a package that Tuna or an example directly imports may be added after the pre-metadata import review. Tuna keeps `net-lib` because it directly imports that package's collections. Under the required Racket 9.2 runtime, `xml` resolves from `base` at `collects/xml/main.rkt`; the configured catalogs provide neither `xml` nor `xml-lib`, so declaring `xml-lib` makes a clean install fail before Tuna setup. `xml-lib` is therefore not a dependency. Do not add a transitive dependency merely because an SDK uses it. Any discovered direct dependency is a factual metadata correction within the approved topology, not a new architecture decision; an import that would reverse the approved core/example direction is instead a blocking architecture violation.

The `#:version` form specifies a **minimum acceptable package version**, not an exact version or Git revision. Thus `("datastar-lib" #:version "0.4")` cannot select commit `2389f978f16f279bb39c5ccc3776e17236c91b95`. Reproducible clean-install acceptance separately binds the catalog install and installed-package postcheck to that exact checksum. Tuna depends on `datastar-lib`, whose collection is `"datastar"`; it does not depend on umbrella package `datastar`, which would unnecessarily add `datastar-doc`.

### Exact launcher and CLI contract

The core package's only launcher declarations are:

```racket
(define racket-launcher-names '("tuna"))
(define racket-launcher-libraries '("main.rkt"))
```

The paired lists have equal length. The library is collection-relative, so it is exactly `"main.rkt"`, not `"tuna/main.rkt"` or a filesystem path; setup resolves it as the equivalent collection load `-l- tuna/main.rkt`. `packages/tuna/main.rkt` is program-capable and is the sole declared launcher entry. No launcher flags are declared absent a demonstrated implementation requirement.

The launcher accepts exactly three argument shapes after converting `current-command-line-arguments` to a list: `()`, `("--config" FILE)`, or `("--no-config")`. `--config FILE` requires a nonempty existing path and replaces default selection; `--no-config` disables configuration. Conflicts, repetitions, missing values, extra arguments, `--help`, `-h`, and bare `--` fail through Tuna's usage-error path. An unadapted `racket/cmdline` parser is not used to silently acquire its built-in help/end-of-options behavior.

No arguments selects an existing default configuration or none: a nonempty `XDG_CONFIG_HOME` supplies its `tuna/config.ss`; otherwise the Unix baseline uses `$HOME/.config/tuna/config.ss`; if `HOME` is absent, the application installation-root fallback is used. This path-selection contract is validated independently of `PLTUSERHOME` and is consistent with ADR 0001's installed shared-registry evaluator.

### Private root-level asset module

The Tuna package owns one private **root-level** module (under `packages/tuna/`, not below `private/`) that imports `racket/runtime-path` and declares exactly:

```racket
#lang racket/base
(require racket/runtime-path)

(define-runtime-path datastar-js
  "assets/datastar-v1.0.2.js")
(define-runtime-path keyboard-js
  "assets/tuna-keyboard-v1.js")
```

The module and accessor names may remain private, but the declaration location and relative strings are fixed so compiled/installed lookup resolves against the defining module rather than `current-directory`. Moving the module below `private/` without changing the strings would be wrong and is not part of this contract. ADR 0003 owns exact asset byte/hash/content-type/cache obligations.

### Installation and open extensions

Installation is the deployment model. The `tuna` command is installation-backed and resolves modules through that same Racket installation. Configuration may explicitly import any deliberately installed compiled package and its transformers. The shared namespace/module registry in ADR 0001 preserves intended once-only module instances and live Tuna registry identity.

A finite standalone distribution has a closed declared module set and is non-equivalent for Tuna's open extension contract. Such an artifact requires a separate owner-approved scope change and cannot replace installation-backed acceptance.

## Bounded validation contract

No command in this section is authorized merely by ADR acceptance. Source commands become valid only after their named paths exist. Package installation/setup mutates an environment and requires separate explicit owner authorization. Validation must never modify the user's normal package installation.

### Source tests and compilation

From the repository root, the source-oriented package shape is:

```sh
cd /home/jay/Code/workbench-racket/tuna-racket
PLTCOLLECTS="$PWD/packages:" /home/jay/racket/bin/raco test \
  packages/tuna \
  packages/tuna-example-counter \
  packages/tuna-example-dummy \
  packages/tuna-example-message
```

Assuming each approved collection supplies its conventional `main.rkt`, compilation is:

```sh
cd /home/jay/Code/workbench-racket/tuna-racket
PLTCOLLECTS="$PWD/packages:" /home/jay/racket/bin/raco make \
  packages/tuna/main.rkt \
  packages/tuna-example-counter/main.rkt \
  packages/tuna-example-dummy/main.rkt \
  packages/tuna-example-message/main.rkt
```

The explicit `PLTCOLLECTS="$PWD/packages:"` forces resolution through the four local collections under `packages/`, preventing a stale installed Tuna from satisfying source validation. Its trailing empty element preserves Racket's default collection paths.

Imported leaf modules compile transitively. The final import-exhaustiveness review precedes final metadata and records any additional direct package dependency; it does not invent a complete leaf list before source exists.

### Superseding operational note for the owner-authorized validation run

For this validation run, the owner-authorized catalog workflow supersedes the earlier local-checkout copy workflow for Datastar below. The harness first requires the configured catalog's `datastar-lib` entry to report checksum `2389f978f16f279bb39c5ccc3776e17236c91b95`, installs `datastar-lib` with `raco pkg install --checksum` bound to that value, and then requires `raco pkg show --full-checksum` to report the same value. Catalog attestation, checksum-bound installation, and the installed-package postcheck all run inside the temporary `PLTUSERHOME`; normal user package state is not used. The local Tuna packages continue to use `--copy` in the stated core-then-examples order. The executable contract is `tests/clean-install/run.rkt`, with its pin in `tests/clean-install/manifest.rktd` and operator instructions in `tests/clean-install/README.md`.

The following local-checkout Datastar procedure is retained only as the superseded operational record; it does not govern this validation run and must not be substituted for the checksum-bound catalog workflow.

### Superseded local-checkout copied installation

The former isolated installation shape was:

```sh
ISO="$(mktemp -d)" || {
  echo "error: could not create isolated PLTUSERHOME" >&2
  exit 1
}
UNRELATED="$(mktemp -d)" || {
  status=$?
  rm -rf -- "$ISO"
  echo "error: could not create unrelated working directory" >&2
  exit "$status"
}
cleanup() {
  status=$?
  rm -rf -- "$ISO" "$UNRELATED"
  return "$status"
}
trap cleanup EXIT
set -e
export PLTUSERHOME="$ISO"

if ! SDK_HEAD="$(git -C /home/jay/Code/datastar-racket rev-parse HEAD)" ||
   ! SDK_STATUS="$(git -C /home/jay/Code/datastar-racket status \
     --porcelain=v1 --untracked-files=all)" ||
   test "$SDK_HEAD" != 2389f978f16f279bb39c5ccc3776e17236c91b95 ||
   test -n "$SDK_STATUS"; then
  echo "error: datastar-racket must be at exact clean revision 2389f978f16f279bb39c5ccc3776e17236c91b95" >&2
  exit 1
fi

/home/jay/racket/bin/raco pkg install --scope user --copy --auto \
  --name datastar-lib /home/jay/Code/datastar-racket/datastar-lib

/home/jay/racket/bin/raco pkg install --scope user --copy --auto \
  --name tuna /home/jay/Code/workbench-racket/tuna-racket/packages/tuna

/home/jay/racket/bin/raco pkg install --scope user --copy --auto \
  --name tuna-example-counter \
  /home/jay/Code/workbench-racket/tuna-racket/packages/tuna-example-counter

/home/jay/racket/bin/raco pkg install --scope user --copy --auto \
  --name tuna-example-dummy \
  /home/jay/Code/workbench-racket/tuna-racket/packages/tuna-example-dummy

/home/jay/racket/bin/raco pkg install --scope user --copy --auto \
  --name tuna-example-message \
  /home/jay/Code/workbench-racket/tuna-racket/packages/tuna-example-message
```

The order is pinned SDK, core, counter, dummy, message. `--copy` proves independence from source paths; `--auto` may resolve declared catalog dependencies, so an offline/hermetic run requires a separately approved dependency mirror. Before the SDK copy installation, the revision assertion requires the exact pinned `HEAD`, and the empty porcelain-status assertion rejects both tracked and untracked dirt. Each temporary-directory assignment fails closed; if the second creation fails, the first directory is removed before exit. After both exist, the single `EXIT` trap preserves the incoming status while removing them, and `set -e` makes the installs and subsequent harness commands stop at the first failure so neither later success nor `--auto` can mask it. The temporary `PLTUSERHOME` and trap confine cleanup to the temporary environment created by the harness; no normal user package installation is used.

Discover the installed launcher without assuming a platform-specific bin path. The following unrelated-CWD invocation is the required inner child-command shape; the bounded `/home/jay/Code/workbench-racket/tuna-racket/tests/clean-install/` process harness must supply its timeout, known child identity, stop, wait, and cleanup rather than running it as an unbounded foreground server:

```sh
TUNA_BIN="$(
  PLTUSERHOME="$ISO" /home/jay/racket/bin/racket -e \
    '(require setup/dirs)
     (display (build-path (find-user-console-bin-dir) "tuna"))'
)"

(
  cd "$UNRELATED"
  PLTUSERHOME="$ISO" "$TUNA_BIN" --no-config
)
```

The launcher test also exercises `--config FILE` using fixtures created by the approved `tests/clean-install/` harness, rather than claiming a literal fixture or output path before implementation. The exact acceptance harness path is `/home/jay/Code/workbench-racket/tuna-racket/tests/clean-install/`; that harness/manifest supplies bounded server lifecycle, exact fixtures, expected outputs, timeouts, known child process identity, and cleanup. It must also reject all non-approved CLI shapes.

### Open installed-extension proof

The `/home/jay/Code/workbench-racket/tuna-racket/tests/clean-install/` harness must:

1. install/attest exact SDK revision, then install `tuna` and confirm the launcher from an unrelated CWD;
2. install examples as separate packages (including a run where `tuna-example-dummy` is installed only after core) and invoke the same launcher with `--config FILE` naming a harness fixture;
3. have that fixture explicitly import installed dummy values and transformers, and separately cover counter/message imports according to their public contracts;
4. assert once-only dummy initialization, compiled-caller/live-registry behavior, and ordinary transformer use;
5. assert exact installed bytes and hashes for `assets/datastar-v1.0.2.js` and `assets/tuna-keyboard-v1.js` from the unrelated CWD;
6. use bounded lifecycle controls and deterministic cleanup of only its temporary directories/environment.

Where fixture names, child output, or lifecycle-control details necessarily await implementation, the authoritative path is the approved `tests/clean-install/` harness above; this ADR does not invent unknown literals.

## Rejected alternatives

- **One package containing core and all examples:** makes example policy part of core's dependency closure and weakens independent-extension proof.
- **Core depending on examples:** reverses the approved ownership direction.
- **Umbrella `datastar`:** adds documentation rather than the one runtime package Tuna needs.
- **Treating `datastar-lib` 0.4 as a revision pin:** package floors cannot attest commit `2389f978f16f279bb39c5ccc3776e17236c91b95`.
- **Adding transitive dependencies preemptively:** metadata records direct imports, not another package's implementation closure.
- **Launcher library `"tuna/main.rkt"` or filesystem path:** launcher libraries are collection-relative.
- **CWD-relative assets or a nested asset module with unchanged strings:** fails installed/unrelated-CWD resolution.
- **Normal-user package installation or linked source install as acceptance:** does not prove isolation or copied installation and risks user state.
- **Finite standalone executable:** cannot import future deliberately installed compiled modules/transformers.
- **Literal Gerbil package names, build counts, or command transliteration:** Racket metadata and collection boundaries differ.

## Consequences

### Behavioral and public

The installed public API remains under `tuna/...`; example APIs remain in three separately installed collections. Compiled extension modules can initialize once in the intended registry, compiled callers can traverse live wrappers, and configuration can import installed runtime exports and transformers without CWD dependence. The launcher has one stable installation-backed entry and strict `--config FILE`/`--no-config` behavior. Public export-list tests prevent private helpers or example policy from leaking into core.

### Security, lifecycle, and ecosystem

Open imports are limited by deliberate package installation, not config sandboxing; installed extension code is trusted and can execute arbitrary effects. Launcher and evaluator use the same installation/registry. Exact assets are package-owned resources resolved with `define-runtime-path`. The exact catalog and installed-package checksum is an operational acceptance requirement beyond metadata's minimum version. Missing/incompatible Racket 9.2 package evidence or a direct import that violates dependency direction blocks implementation rather than authorizing fetch, substitution, or redesign.

## Validation obligations

Static pre-metadata review confirms all four exact string collections, dependency arrows, direct-import package mapping, launcher keys/library, and root-level runtime paths. Source/RackUnit and separately compiled tests prove public exports, compiled callers, once-only dummy initialization, live replacement, and transformer imports.

After separate owner authorization, the exact temporary-`PLTUSERHOME` workflow verifies the catalog checksum before installation, binds the Datastar install to that checksum, postchecks the installed full checksum, and then verifies package order, four independent Tuna packages, launcher discovery/execution from an unrelated CWD, strict CLI shapes, installed assets, and open extensions through `/home/jay/Code/workbench-racket/tuna-racket/tests/clean-install/`. No validation runs against the normal user installation.

## Primary-source contracts

- Single-collection strings and dependency forms: `/home/jay/racket/collects/pkg/private/metadata.rkt:18-75,126-147`; version comparison semantics: `/home/jay/racket/collects/pkg/db.rkt:67-74`.
- Launcher canonical keys and list matching: `/home/jay/racket/collects/raco/info.rkt:5-6`, `/home/jay/racket/collects/setup/setup-core.rkt:1630-1694`; collection-relative launcher construction: `/home/jay/racket/collects/launcher/launcher.rkt:933-955`; package install discovery: `/home/jay/racket/collects/pkg/private/addl-installs.rkt:110-124`.
- Module-relative compiled/installed resource semantics: `/home/jay/racket/collects/racket/runtime-path.rkt:1-20,82-99,169-212`.
- SDK collection, version, and dependencies: `/home/jay/Code/datastar-racket/datastar-lib/info.rkt:1-16`; umbrella package implication: `/home/jay/Code/datastar-racket/datastar/info.rkt:1-13`; protocol/CDN v1.0.2: `/home/jay/Code/datastar-racket/datastar-lib/sugar.rkt:1-16`; SDK provenance: `/home/jay/Code/datastar-racket/sdk-tests/README.md:1-13`.
- Target runtime identity: `/home/jay/racket/README:1-10` (Racket CS 9.2). `web-server-lib` 1.13 metadata/source identity is also recorded by ADR 0003.
- Exact CLI data source and shape mechanism: Racket 9.2 [Runtime Configuration §15.1](https://download.racket-lang.org/releases/9.2/doc/reference/runtime.html) (`current-command-line-arguments`) and [Pattern Matching](https://download.racket-lang.org/releases/9.2/doc/reference/match.html); rejected parser built-ins: [Command-Line Parsing §15.9](https://download.racket-lang.org/releases/9.2/doc/reference/Command-Line_Parsing.html), `/home/jay/racket/collects/racket/cmdline.rkt:241-246,354-430`.

## Traceability

- **Baseline IDs:** `CFG-01`, `CFG-03`, `CFG-05`, `WEB-11`, `PKG-01`, `PKG-02`, `PKG-04`, `PKG-05`, `PKG-06`, `VAL-01`, `VAL-02`.
- **Matrix pattern IDs:** `CFG-01b`, `CFG-01c`, `CFG-03`, `CFG-05b`, `CFG-05c`, `CFG-05d`, `WEB-01/11`, `PKG-01`, `PKG-02`, `PKG-04`, `PKG-05`, `PKG-06`, `VAL-01`, `VAL-02`.
