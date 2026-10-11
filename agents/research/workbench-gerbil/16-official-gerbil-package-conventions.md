# Official Gerbil Package Conventions

## Scope and provenance

Evidence was reviewed from `/home/jay/Code/gerbil` at commit `0618730d4e30bf3f48538d6b09722ad3b6056414`, principally the package, build, and test documentation plus the corresponding implementations and generated project template.

## Conclusions

### 1. Minimum package contract

A publishable Gerbil package is a supported-provider Git repository containing:

1. `gerbil.pkg`, an s-expression property list; and
2. an executable build script, normally `build.ss`.

The package guide says `gerbil.pkg` should nominally contain:

- `package: <symbol>` — the common package/module prefix, recursively applied to source files;
- `depend: <list>` — package-manager identities of dependencies.

The build script must expose `meta`, `spec`, and `compile`, with a default action that compiles. `:std/build-script`/`defbuild-script` is the recommended implementation.  
Evidence: `/home/jay/Code/gerbil/doc/guide/package-manager.md:21-37`; `/home/jay/Code/gerbil/src/std/build-script.ss:9-43`.

Current source also recognizes:

- `build:` to select a build script other than `build.ss`;
- `prelude:` and `namespace:` while resolving modules;
- empty `gerbil.pkg` files as package boundaries.

These are implemented capabilities, but only `package:` and `depend:` are presented as the nominal public package metadata contract.  
Evidence: `/home/jay/Code/gerbil/src/tools/gxpkg.ss:1035-1063`; `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:354-387,490-503`.

### 2. Package identity and import identity are distinct

The external package-manager identity is normally a repository path such as:

```text
github.com/organization/repository
```

The import identity comes from the `package:` prefix plus the source path beneath the package root:

```scheme
(package: acme)
;; source: widget/parser.ss
(import :acme/widget/parser)
```

The file itself supplies the final module-name component. Its canonical runtime namespace is correspondingly `acme/widget/parser#`. Relative imports such as `./parser` and `../shared` are supported.  
Evidence:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1100-1115,1151-1204`
- `/home/jay/Code/gerbil/doc/reference/std/make.md:125-137`
- `/home/jay/Code/gerbil/doc/guide/ffi.md:29-50`
- `/home/jay/Code/gerbil/doc/guide/eval.md:129-148`

The repository identity need not equal the namespace. The build guide’s `github.com/mighty-gerbils/gerbil-libxml` example installs modules under the `clan/xml` prefix.  
Evidence: `/home/jay/Code/gerbil/doc/reference/dev/build.md:368-400`.

`gerbil.pkg` lookup walks upward from a source file, collecting intervening directory names and applying the first package boundary it encounters. This is how a root `(package: vyzo)` plus `hello/lib.ss` becomes `vyzo/hello/lib`.  
Evidence: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:354-390`.

### 3. Official source-tree convention

There is no required `src/`, `test/`, `doc/`, or `examples/` directory.

`gerbil new` creates this shape:

```text
project/
├── gerbil.pkg
├── build.ss
├── Makefile
├── .gitignore
└── <project-name>/
    ├── lib.ss
    └── main.ss
```

The namespace defaults to the username, while the generated source directory defaults to the current/project name. The build specification lists paths relative to the directory containing `build.ss`.  
Evidence:

- `/home/jay/Code/gerbil/doc/guide/getting-started.md:105-194`
- `/home/jay/Code/gerbil/doc/reference/dev/build.md:152-179,245-254`
- `/home/jay/Code/gerbil/doc/reference/std/make.md:112-137`
- `/home/jay/Code/gerbil/src/tools/gxpkg.ss:352-383,1134-1234`

Materially different valid layouts therefore include:

- sources directly beside `gerbil.pkg`;
- sources under a package/project-named directory, as generated;
- deeper module directories mirroring desired import paths;
- a separate test tree, provided recursive discovery is requested.

### 4. Build system

The documented recommendation is:

```scheme
#!/usr/bin/env gxi
(import :std/build-script)

(defbuild-script
  '("widget/lib"
    (exe: "widget/main" bin: "widget")))
```

`defbuild-script` supplies `meta`, `spec`, `compile`, `clean`, and default compilation actions. Build specifications explicitly name library modules, executables, copied data, FFI components, and other targets; dependencies between modules are automatically detected.  
Evidence:

- `/home/jay/Code/gerbil/doc/reference/dev/build.md:27-52`
- `/home/jay/Code/gerbil/doc/reference/std/make.md:20-124`
- `/home/jay/Code/gerbil/src/std/build-script.ss:9-43`

The preferred invocation is:

```sh
gerbil build
```

Release and whole-program variants are:

```sh
gerbil build --optimized
gerbil build --release --optimized
```

When `GERBIL_PATH` is not explicitly set, local package commands use a project-local `.gerbil` environment instead of contaminating `~/.gerbil`.  
Evidence: `/home/jay/Code/gerbil/doc/reference/dev/build.md:92-148`; `/home/jay/Code/gerbil/src/tools/env.ss:20-36`.

### 5. Dependencies, manifests, and generated files

#### `depend:`

Dependencies are repository/package-manager identities, optionally suffixed by `@tag`. They can be managed with:

```sh
gerbil deps -a -i github.com/org/package
```

Installation recursively fetches declared dependencies before building the requested package.  
Evidence: `/home/jay/Code/gerbil/src/tools/gxpkg.ss:95-111,396-419`.

#### `build-deps`

`build-deps` is not a dependency declaration. It is a generated/cache file recording inputs and build times. Its default location is the source/build root. Separate build specifications sharing a root need distinct `build-deps:` paths to avoid cache collisions.  
Evidence: `/home/jay/Code/gerbil/doc/reference/std/make.md:210-219`; `/home/jay/Code/gerbil/src/std/make.ss:68-110`.

#### `manifest.ss`

Before package compilation, `gxpkg` generates `manifest.ss`, defining `version-manifest` from the current package revision, Gerbil, Gambit, and transitive package manifests. Installed dependencies additionally get adjacent `<package>.manifest` files under the package store.  
Evidence:

- `/home/jay/Code/gerbil/doc/reference/dev/build.md:403-425,478-504`
- `/home/jay/Code/gerbil/src/tools/gxpkg.ss:653-727`
- `/home/jay/Code/gerbil/src/tools/gxpkg.ss:1146-1151`

#### Ignored/generated outputs

The official generator’s `.gitignore` contains:

```text
*~
build-deps
/manifest.ss
.gerbil
```

Thus `build-deps`, root `manifest.ss`, and `.gerbil/` are officially treated as generated files, not publication sources.  
Evidence: `/home/jay/Code/gerbil/src/tools/gxpkg.ss:1228-1234`.

`.gerbil/bin` contains executables, `.gerbil/lib` contains compiled libraries and compiler artifacts, and `.gerbil/pkg` contains cloned/linked dependencies. Typical generated library artifacts include `.ssi`, `.ssxi.ss`, `.scm`, and Gambit object files.  
Evidence: `/home/jay/Code/gerbil/doc/reference/dev/build.md:314-400`; `/home/jay/Code/gerbil/doc/guide/env-vars.md:5-18`.

### 6. Test discovery, naming, and placement

#### Documented naming contract

Official documentation explicitly states:

- test files conventionally end in `-test.ss`;
- they are generally not compiled;
- each is a module exporting one or more runtime test suites whose exported names end in `-test`;
- optional `test-setup!` and `test-cleanup!` exports provide file-level fixtures.

Evidence: `/home/jay/Code/gerbil/doc/reference/dev/test.md:6-15`.

#### Discovery and commands

```sh
gerbil test                  # immediate current directory only
gerbil test some-test.ss     # explicit file
gerbil test path/to/tests    # immediate tests in that directory
gerbil test ./...            # recursively discover all *-test.ss
```

Directory discovery filters strictly on `-test.ss`; an explicitly supplied file is accepted directly. Recursive discovery only occurs with the `/...` suffix. Exported runtime names ending in `-test` become suites.  
Evidence:

- `/home/jay/Code/gerbil/doc/reference/dev/test.md:17-25`
- `/home/jay/Code/gerbil/doc/reference/dev/bach.md:194-208`
- `/home/jay/Code/gerbil/src/tools/gxtest.ss:93-151`

For an isolated package environment, the build guide gives:

```sh
gerbil pkg env gxtest ./...
```

Current `gxtest` also calls the local environment setup directly, so `gerbil test ./...` is package-local when run from a directory containing `gerbil.pkg`, unless a global environment is explicitly selected or `GERBIL_PATH` is already set.  
Evidence: `/home/jay/Code/gerbil/doc/reference/dev/build.md:591-603`; `/home/jay/Code/gerbil/src/tools/gxtest.ss:20-43`; `/home/jay/Code/gerbil/src/tools/env.ss:20-36`.

#### Is `*-test.ss` beside the module documented or conventional?

**Yes, with an important qualification.**

- The `-test.ss` suffix is explicitly documented as a convention.
- Co-location beside the tested module is demonstrated by the official example: `mylib.ss` and `mylib-test.ss` are created in the same directory and the test imports `./mylib`.  
  Evidence: `/home/jay/Code/gerbil/doc/reference/dev/test.md:37-66`.
- Gerbil’s standard library follows this pattern extensively; for example:
  - `/home/jay/Code/gerbil/src/std/assert.ss:1-10`
  - `/home/jay/Code/gerbil/src/std/assert-test.ss:1-18`
  - `/home/jay/Code/gerbil/src/std/db/postgresql.ss:1-18`
  - `/home/jay/Code/gerbil/src/std/db/postgresql-test.ss:1-17`

The reviewed standard-library tree contains 92 `*-test.ss` files, many beside their corresponding modules.

However, **the documentation does not require co-location**. A centralized test directory is valid if it uses suitable imports and is explicitly or recursively passed to `gxtest`. Therefore:

> `foo-test.ss` beside `foo.ss` is the clearest documented and repository-backed convention, but only the suffix/export rules are discovery contracts.

### 7. Documentation and examples

README, license, documentation, and example files are useful publication content but are not package-manager requirements. The package guide’s acceptance list requires only `gerbil.pkg` and the build script. The generated template creates neither README nor docs/examples/tests.  
Evidence:

- `/home/jay/Code/gerbil/doc/guide/package-manager.md:21-37`
- `/home/jay/Code/gerbil/src/tools/gxpkg.ss:352-383,1134-1234`

Gerbil’s tutorials commonly keep runnable example source under `src/tutorial/<name>` with a local `gerbil.pkg` and `build.ss`, but that is a monorepo/example organization rather than a package rule.  
Evidence: `/home/jay/Code/gerbil/doc/tutorials/proxy.md:18-29`; `/home/jay/Code/gerbil/src/tutorial/proxy/gerbil.pkg:1`; `/home/jay/Code/gerbil/src/tutorial/proxy/build.ss:1-10`.

### 8. Installation and publication

Publication does not involve uploading an archive to a central registry. Any public GitHub, GitLab, or Bitbucket repository can be installed by provider path when it meets the package contract:

```sh
gerbil pkg install github.com/org/repository
```

Installation clones/fetches the repository, installs declared dependencies, generates manifests, and invokes the package build. Sources live under the active Gerbil package store; build outputs go to its `lib` and `bin` directories.  
Evidence:

- `/home/jay/Code/gerbil/doc/guide/package-manager.md:3-6,21-43`
- `/home/jay/Code/gerbil/src/tools/gxpkg.ss:396-419,461-491`
- `/home/jay/Code/gerbil/src/tools/gxpkg.ss:1118-1126`

A package becomes searchable by inclusion in a `package-list`. Package directories may be GitHub repositories containing `package-list` or direct URLs; list entries are association-list records whose only required property is `description:`. Direct installation by repository path does not depend on directory registration.  
Evidence: `/home/jay/Code/gerbil/doc/guide/package-manager.md:71-92`; `/home/jay/Code/gerbil/src/tools/gxpkg.ss:819-830,906-940`.

Git tags provide versions. Dependencies may append `@<version-tag>`; tags of form `vX[.Y[.Z]]` are compared, while `main` and `master` rank above semantic tags. Gerbil does not enforce semantic-version major compatibility.  
Evidence: `/home/jay/Code/gerbil/doc/reference/dev/build.md:560-589`.

## Evidence-backed validation commands

These were not executed because this was a read-only research task.

Focused module/test validation:

```sh
cd /path/to/package
gerbil build
gerbil test path/to/module-test.ss
```

Immediate-directory test discovery:

```sh
cd /path/to/package/source-directory
gerbil test
```

Full isolated package validation:

```sh
cd /path/to/package
gerbil build
gerbil pkg env gxtest ./...
```

Equivalent current-tool full test invocation after building:

```sh
cd /path/to/package
gerbil test ./...
```

## Risks and unresolved gaps

- **Low — documentation is not exhaustive:** `build:`, `namespace:`, and `prelude:` are supported by source but not fully specified by the package-manager guide.
- **Low — minor documentation drift:** the build guide recommends `gerbil pkg env gxtest`, while current `gxtest` automatically establishes a local package environment.
- **Low — co-location strength:** co-located `foo-test.ss` is strongly demonstrated and widely practiced, but no normative sentence requires that placement.
- **Medium — installation trust:** package build scripts execute arbitrary code with user privileges and are not sandboxed or signed. The official guide advises reviewing sources before installation. Evidence: `/home/jay/Code/gerbil/doc/guide/package-manager.md:94-106`.
- **Low — publication governance:** the documentation explains package-list format and custom directories but does not document an acceptance process for the default Mighty Gerbils directory.

## Confidence

**High** for package shape, namespace identity, generated files, testing, installation, and the `*-test.ss` conclusion; these are corroborated by documentation, current implementation, generator templates, and Gerbil’s own source layout.