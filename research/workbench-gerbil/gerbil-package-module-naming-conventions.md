# Gerbil package and module naming conventions

## Recommendation

For **sse-gerbil**, publish the public module as **`:jay/sse`** now:

```scheme
;; gerbil.pkg
(package: jay)
```

```scheme
;; build.ss
(defbuild-script '("sse"))
```

Keep `sse.ss`; consumers import:

```scheme
(import :jay/sse)
```

This is the best balance of Gerbil convention, relocation safety, and KISS/YAGNI:

- Gerbil’s guide recommends a top package namespace to prevent collisions and defaults new projects to the user name (`doc/guide/getting-started.md:105-123`).
- 14 of 21 surveyed third-party packages use a shared vendor/community prefix such as `clan`, `ober`, or `jafourni`.
- Every surveyed single-purpose library still has a meaningful leaf module; none publishes only a package-free `:module`.
- `:jay/sse` describes exactly one SSE module without suggesting speculative sibling transports.
- A disposable Gerbil v19 consumer test confirmed `:jay/sse` is relocation-safe.

If a personal namespace is unacceptable, use **`:sse/sse`**. That repetition is less elegant but is established in practice by paths such as `:clan/persist/persist`, `:redis/redis`, and `:sinatra/sinatra`.

Do **not** use `:sse/http` merely because it works. SSE is inherently an HTTP server-push protocol, and the package currently implements only that one integration. The `http` leaf implies a meaningful sibling axis—other transports or transport families—that does not exist. It would become justified only if the package were deliberately organized around multiple HTTP implementations or adapters.

Avoid `:sse/main`: Gerbil’s generated `main.ss` is an executable entry point, and no surveyed package documents `main` as its primary library API. `:sse/lib` is generator-compatible but less descriptive than `sse`.

The current `:sse` layout is valid according to the source-hierarchy documentation, but **not safely publishable through current Gerbil v19**. That is a Gerbil compiler/package-boundary bug, not a naming error. Fixing Gerbil is worthwhile for platform correctness, but is not justified as a release prerequisite merely to save one path segment.

Confidence: **high** for the recommendation and resolver diagnosis; **medium-high** for ecosystem prevalence because git.cons.io is small and maintainer-skewed.

---

## Authoritative Gerbil v19 behavior

The local documentation/source inspected is commit
`f51678a4a0b9ccfa8ca6bf4207487373500ae410`
(`v0.19-dev-57-gf51678a4`). The installed compiler used for disposable tests is
`Gerbil v0.19-dev-31-g4a4d1a30`.

### Package, file, and module are separate identities

A repository locator such as:

```text
git.cons.io/jay/gerbil-sse
```

does not determine the import path. The import ID comes from:

1. the `package:` prefix;
2. intervening source directories;
3. the source filename without its extension.

Gerbil documents library paths as `:symbol[/symbol]*`, with `/` acting as the filesystem separator:

- `gerbil-dev/doc/reference/gerbil/prelude/core-expander-syntax.md:34-60`

The package manager calls `package:` the common recursive source prefix:

- `gerbil-dev/doc/guide/package-manager.md:22-35`

The build reference gives the concrete mapping: prefix `legs` plus `foo/bar.ss` produces `:legs/foo/bar`:

- `gerbil-dev/doc/reference/std/make.md:124-131`

The expander implements that mapping by walking upward for `gerbil.pkg`, accumulating directories, and appending the source basename:

- package discovery: `gerbil-dev/src/gerbil/expander/module.ss:358-396`
- module construction: `gerbil-dev/src/gerbil/expander/module.ss:269-272`

Consequently:

| Repository | Package prefix | Source | Import |
|---|---|---|---|
| `git.cons.io/jay/gerbil-sse` | `jay` | `sse.ss` | `:jay/sse` |
| same | `sse` | `sse.ss` | `:sse/sse` |
| same | `sse` | `http.ss` | `:sse/http` |
| same | empty boundary | `sse.ss` | nominally `:sse` |

### Normative naming guidance

The strongest local naming recommendation is:

> “use a top package for your libs so that you don't have conflicts with other packages.”

Gerbil’s project generator defaults that prefix to the current user and creates `<project>/lib.ss` and `<project>/main.ss`:

- `gerbil-dev/doc/guide/getting-started.md:105-155`
- `gerbil-dev/src/tools/gxpkg.ss:364-379`
- generator templates: `gerbil-dev/src/tools/gxpkg.ss:1134-1168`

The introductory guide instead uses a product package plus a descriptive module, `example/util.ss` → `:example/util`:

- `gerbil-dev/doc/guide/intro.md:1192-1234`

Thus both vendor-oriented and product-oriented namespaces are supported. Neither documentation nor source connects the Git repository name to the Gerbil package prefix.

### Empty package boundaries

The guide explicitly says an empty `gerbil.pkg` is an empty package boundary:

- `gerbil-dev/doc/guide/intro.md:1378-1399`

At source time, `core-read-module-package` honors it:

- `gerbil-dev/src/gerbil/expander/module.ss:367-376`

However, `std/make` compiles into `$GERBIL_PATH/lib` and does not install that empty boundary:

- prefix/lib setup: `gerbil-dev/src/std/make.ss:76-95`
- compilation output: `gerbil-dev/src/std/make.ss:511-527`
- library paths: `gerbil-dev/src/std/make.ss:670-674`

When a consumer later reads the installed `sse.ssi`, package discovery continues above `.gerbil/lib` into the consumer repository. It can therefore infer `datastar/.gerbil/lib/sse` rather than `sse`.

The existing reproduction and alternatives are documented at:

- `research/sse-top-level-package-install-audit.md:14-35`
- `research/sse-top-level-package-install-audit.md:61-72`
- `research/sse-top-level-package-install-audit.md:74-106`

There is no current module declaration that distinguishes “explicitly package-free” from “package not specified”:

- `package: #f` is parsed as false: `module.ss:244-253`
- false then triggers filesystem inference: `module.ss:255-258`

### HTTP naming analogue

Gerbil v19’s own HTTP implementation uses a real domain hierarchy because it has meaningful siblings:

- package root: `gerbil-dev/src/std/gerbil.pkg:1`
- `net/http/client.ss` re-exports client APIs: `gerbil-dev/src/std/net/http/client.ss:1-5`
- `net/http/server.ss` re-exports server APIs: `gerbil-dev/src/std/net/http/server.ss:1-5`
- resulting modules: `:std/net/http/client` and `:std/net/http/server`

That is materially different from sse-gerbil: `http` is a domain node above actual `client` and `server` siblings. In `:sse/http`, `http` would be a terminal leaf without a demonstrated sibling taxonomy.

---

## git.cons.io survey

### Method and scope

The public Forgejo API listed 72 repositories. The sample selected 21 installable, non-core packages across Mighty Gerbils and Ober, plus the two Jay repositories under review. Core Gerbil/Gambit mirrors, non-Gerbil repositories, and repositories without `gerbil.pkg`/`build.ss` were excluded.

Each surveyed repository was shallow-cloned into `/tmp`, inspected at the commit shown below, and removed afterward. Build scripts were inspected rather than executed because Gerbil documents them as arbitrary, unsandboxed code (`doc/guide/package-manager.md:94-100`) and several require foreign libraries.

“Documented” below means the README or package documentation shows the import. “Inferred” means it follows from the committed package boundary, source path, and build target.

### Package survey

| Repository and commit | `gerbil.pkg` contents | Source/layout and build targets | Resulting/documented imports | Shape |
|---|---|---|---|---|
| [mighty-gerbils/gerbil-leveldb@65b2970](https://git.cons.io/mighty-gerbils/gerbil-leveldb/src/commit/65b2970719ce2672366cd6d10d7b31622ba56073) | `(package: clan)` | `db/_leveldb` foreign/SSI; `db/leveldb`; test target | **Documented** `:clan/db/leveldb` | Single-purpose wrapper |
| [mighty-gerbils/gerbil-libp2p@772cee0](https://git.cons.io/mighty-gerbils/gerbil-libp2p/src/commit/772cee0b7e114d3f13d5c660108e7c82da9b03dc) | `(package: clan)` | sole target `libp2p/interface.ss` | **Inferred** `:clan/libp2p/interface` | Single module |
| [mighty-gerbils/gerbil-libxml@e190703](https://git.cons.io/mighty-gerbils/gerbil-libxml/src/commit/e190703385b5fd3d2642133c3ebf38bf932368b0) | `(package: clan)` | `xml/_libxml` foreign/SSI; `xml/libxml` | **Documented** `:clan/xml/libxml` | Single-purpose wrapper |
| [mighty-gerbils/gerbil-libyaml@8df8bd5](https://git.cons.io/mighty-gerbils/gerbil-libyaml/src/commit/8df8bd53cdb4c4db61b724827cda3d10cfec5387) | `(package: clan)` | `text/libyaml` foreign/SSI; `text/yaml` | **Documented** `:clan/text/yaml` | Single-purpose wrapper |
| [mighty-gerbils/gerbil-lmdb@973671c](https://git.cons.io/mighty-gerbils/gerbil-lmdb/src/commit/973671c3d3c212e754b4304e532c4a49e5b876b7) | `(package: clan)` | `db/_lmdb` foreign/SSI; `db/lmdb` | **Documented** `:clan/db/lmdb` | Single-purpose wrapper |
| [mighty-gerbils/gerbil-mysql@847b4b6](https://git.cons.io/mighty-gerbils/gerbil-mysql/src/commit/847b4b61747152e505dfc72acee4438009302c5f) | `(package: clan)` | `db/_mysql` foreign/SSI; `db/mysql` | **Documented** `:clan/db/mysql` | Single-purpose wrapper |
| [mighty-gerbils/gerbil-crypto@c8c17ac](https://git.cons.io/mighty-gerbils/gerbil-crypto/src/commit/c8c17ac0e996ebfb65c4b9024b2a93a21d40df7c) | `(package: clan/crypto depend: ("…/gerbil-utils" "…/gerbil-poo"))` | Flat root targets `keccak`, `blake2`, `bls[-ffi]`, `ed25519[-ffi]`, `secp256k1[-ffi]`, `password`, `random`, `version` | Inferred `:clan/crypto/random`, `:clan/crypto/blake2`, etc. | Multi-module |
| [mighty-gerbils/gerbil-persist@6801492](https://git.cons.io/mighty-gerbils/gerbil-persist/src/commit/6801492baa95c34fcbfb2def86556816baf443a3) | `(package: clan/persist depend: ("…/gerbil-utils" "…/gerbil-poo" "…/gerbil-crypto" "…/gerbil-leveldb"))` | Auto-builds flat modules including `persist`, `db`, `kvs`, `kvs-{leveldb,postgres,sqlite,sql}`, `btree`, `merkle-trie`, `content-addressing` | Inferred `:clan/persist/persist` and sibling modules | Multi-module |
| [mighty-gerbils/gerbil-poo@f4b3222](https://git.cons.io/mighty-gerbils/gerbil-poo/src/commit/f4b322299830acbd1cd5b91984c4107ac56bdac3) | `(package: clan/poo depend: ("…/gerbil-utils"))` | Auto-builds root modules `object`, `proto`, `mop`, `type`, `table`, `trie`, `fun`, `io`, etc.; adds `t/table-testing` | Inferred `:clan/poo/object`, `:clan/poo/proto`, etc. | Multi-module |
| [mighty-gerbils/gerbil-utils@f45a4ef](https://git.cons.io/mighty-gerbils/gerbil-utils/src/commit/f45a4ef3bfecd2af39e114ed736ce9082cbb8244) | `(package: clan)` | Auto-builds many root modules and `pure/dict/*`, `net/{tcp,websocket,whois}`; executable `scripts/random-run` | Inferred `:clan/base`, `:clan/net/websocket`, etc. | Large multi-module |
| [ober/gerbil-auth@fe4c5e3](https://git.cons.io/ober/gerbil-auth/src/commit/fe4c5e3d8e51b5bcd9ba9ae583cc294228923bb2) | `(package: jafourni/gerbil-auth)` | `auth/{util,crypto,jwt,oauth2,oidc}/…`; 19 explicit targets | Inferred `:jafourni/gerbil-auth/auth/jwt/jwt`, `…/oauth2/oauth2`, `…/oidc/oidc` | Multi-module |
| [ober/gerbil-cairo@8acc0b7](https://git.cons.io/ober/gerbil-cairo/src/commit/8acc0b78f35f64b9e16a2d459e212f0dc1e2c7aa) | `(package: gerbil-cairo)` | root `libcairo.ss`, `cairo.ss` | Inferred `:gerbil-cairo/cairo` | Single-purpose wrapper |
| [ober/gerbil-charts@797d739](https://git.cons.io/ober/gerbil-charts/src/commit/797d739723e02e6a34cb4e5ea4c108dbaa12eb2a) | `(package: gerbil-charts (depend: …))` | root data/scale/canvas/axis/layout modules; `canvas/{svg,cairo}`; `charts/{line,bar,scatter,area,graph}`; `charts`, `main` | **Documented** `:gerbil-charts/charts/line`, `…/graph`, `:gerbil-charts/graphviz` | Multi-module |
| [ober/gerbil-datadog@9f25e5b](https://git.cons.io/ober/gerbil-datadog/src/commit/9f25e5bf66620aa4d8c9ec9705c1442bece02fb6) | `(package: ober depend: ("github.com/ober/oberlib"))` | `datadog/client`; executable `datadog/datadog` | Inferred `:ober/datadog/client` | Single-purpose client/CLI |
| [ober/gerbil-duckdb@09c5359](https://git.cons.io/ober/gerbil-duckdb/src/commit/09c535990ae0dd7ee23e4c5e537879f25704dbbf) | `(package: clan)` | `db/_duckdb` foreign/SSI; `db/duckdb` | **Documented** `:clan/db/duckdb` | Single-purpose wrapper |
| [ober/gerbil-graphviz@278378e](https://git.cons.io/ober/gerbil-graphviz/src/commit/278378e8ac455e7c0557de0414fd910eaca595cd) | `(package: gerbil-graphviz)` | root `libgraphviz`, `graphviz` | Inferred `:gerbil-graphviz/graphviz` | Single-purpose wrapper |
| [ober/gerbil-pcre2@c50fb0a](https://git.cons.io/ober/gerbil-pcre2/src/commit/c50fb0a792c2c158c759265d8f1c560f07d3ea27) | `(package: gerbil-pcre)` | `pcre2/libpcre2`, `pcre2/pcre2`; benchmark executable | Inferred `:gerbil-pcre/pcre2/pcre2` | Single-purpose wrapper |
| [ober/gerbil-redis@96a2c49](https://git.cons.io/ober/gerbil-redis/src/commit/96a2c49ec2f1553393c58f5f6575aafe83f947a4) | root `(package: redis)`; nested `src/redis/gerbil.pkg` is also `(package: redis)`; commands boundary `(package: redis/commands)` | `resp`, `connection`, `pool`, `pubsub`, command families, umbrella `redis`; nested boundaries intentionally remove `src/redis` from public IDs | **Documented** `:redis/redis`, `:redis/resp` | Multi-module |
| [ober/gerbil-signal@b52dc90](https://git.cons.io/ober/gerbil-signal/src/commit/b52dc907a9a73e7e4f3d4de731f6721a37c649fe) | `(package: signal namespace: signal version: "0.1.0")` | `src/{crypto,proto,core,ratchet,session,store,sender-key,sealed-sender,fingerprint}/…`; umbrella `src/signal` | **Documented** `:signal/src/signal` and all domain modules | Multi-module |
| [ober/gerbil-sinatra@75e5805](https://git.cons.io/ober/gerbil-sinatra/src/commit/75e58052bd8fff840c92808e8ceb776e5f870b87) | `(package: sinatra)` | `sinatra.ss` plus `sinatra/{mime,cookies,session,route,request,response,context,helpers,filters,errors,template,static,logging,middleware,app,handler,dsl}` and tests | Inferred umbrella `:sinatra/sinatra` | Multi-module |
| [ober/gerbil-stats@2fb6846](https://git.cons.io/ober/gerbil-stats/src/commit/2fb68460daefb56b7bf7a636c8f9a8c069711774) | `(package: ober)` | `stats/lib`; executable `stats/main` | Inferred `:ober/stats/lib` | Single-purpose library/CLI |

The two subject packages are:

| Repository and commit | Package/file/build | Public import | Result |
|---|---|---|---|
| [jay/gerbil-sse@55595f1](https://git.cons.io/jay/gerbil-sse/src/commit/55595f18a59d9a545f113d64bdc719d14d032c2a) | empty `gerbil.pkg`; root `sse.ss`; target `"sse"` | documented `:sse` | Direct import works, installed dependency use is not relocation-safe |
| [jay/gerbil-datastar@93d6fcb](https://git.cons.io/jay/gerbil-datastar/src/commit/93d6fcb0a7322bb9e46b549f7a160580d3e6a068) | `(package: datastar depend: ("git.cons.io/jay/gerbil-sse"))`; `http.ss`, `http/api.ss`, `http/private/*`; targets those four modules | documented `:datastar/http` | Namespaced and relocation-safe, but its compiled interface exposes the SSE boundary defect |

Two additional explored repositories, `mighty-gerbils/gerbil-cbor@36479fe` and `mighty-gerbils/gerbil-xlsx@6fa3069`, contained only a README or license at the surveyed commit and were not counted as Gerbil packages.

### Quantified patterns

Across the 21 third-party package sample:

- **21/21** use a non-empty named package prefix.
- **0/21** publish a package-free top-level `:module`.
- **14/21 (67%)** use a shared vendor/community first segment (`clan`, `ober`, or `jafourni`).
- Using one representative public/umbrella module per package:
  - **6/21** have two-segment paths such as `:redis/redis`;
  - **14/21** have three-segment paths such as `:clan/db/lmdb`;
  - **1/21** is deeper (`:jafourni/gerbil-auth/auth/jwt/jwt`).
- Literal adjacent `:package/package` repetition occurs in at least:
  - `:clan/persist/persist`
  - `:redis/redis`
  - `:sinatra/sinatra`
- Semantically repeated project names also occur in:
  - `:gerbil-cairo/cairo`
  - `:gerbil-graphviz/graphviz`
  - `:gerbil-charts/charts`
- One package builds an exact `:gerbil-charts/main`, and `ober/stats` builds `:ober/stats/main` as an executable. **Neither documents `main` as the primary library import.**
- The sole empty-boundary top-level module in the full 23-repository set is the current `:sse`, and it is the one with the relocation failure.

### Single-purpose packages

Twelve surveyed packages are single-purpose libraries or thin foreign wrappers:

- leveldb, libp2p, libxml, libyaml, lmdb, mysql;
- cairo, datadog, duckdb, graphviz, pcre2, stats.

All twelve use a leaf module:

- product/protocol leaves: `leveldb`, `libxml`, `yaml`, `lmdb`, `mysql`, `cairo`, `duckdb`, `graphviz`, `pcre2`;
- role leaves: `interface`, `client`, `lib`.

None uses a package-free top-level module, and none uses `main` as its documented public API. This supports a meaningful `sse` leaf but does not support inventing an `http` subdivision.

### SSE and transport analogues

No independent SSE library analogue was found in the 21-package sample. Supplementary text inspection found SSE parsing/serialization embedded inside application modules in `ober/gerbil-code@354ddd3`, notably `proxy/server.ss` and `provider/provider.ss`, rather than published as a distinct transport module.

Relevant transport naming in the sample and Gerbil itself follows demonstrated domains:

- `:std/net/http/client` and `:std/net/http/server`: real client/server siblings;
- `:clan/net/websocket` and `:clan/net/tcp`: concrete protocol leaves;
- `:clan/libp2p/interface`: interface role leaf;
- `:ober/datadog/client`: client role leaf.

These patterns favor `:<owner>/sse` or `:sse/sse`, not `:sse/http`.

---

## Can gxpkg safely publish exactly `:sse`?

### Current answer: no package-local, relocation-safe method

The following have been tested or established from source:

| Layout/declaration | Outcome |
|---|---|
| Empty root `gerbil.pkg` + `sse.ss` | Nominal `:sse`; fails when consumed from another installed package |
| `package: #f` module header | Same fallback to filesystem inference |
| `(package: sse)` + `sse.ss` | Stable `:sse/sse`, not `:sse` |
| `(package: jay)` + `sse.ss` | Stable `:jay/sse` |
| Copy empty `gerbil.pkg` into `$GERBIL_PATH/lib` | Makes `:sse` work, but package clean removes a shared environment marker |
| Named package while retaining exact `:sse` | Unsupported by current package-plus-basename construction |

A package-owned copied marker is unsafe because `$GERBIL_PATH/lib/gerbil.pkg` is shared by every top-level package in the environment. One package must not own and remove an environment-wide namespace boundary.

### Gerbil-level implementation options

1. **Preserve an explicit package-free module identity in compiled interfaces.**  
   Distinguish “no package declaration” from “explicitly no package” rather than using false for both. This is the principled compiler/expander fix and avoids filesystem-dependent identity after compilation.

2. **Make `$GERBIL_PATH/lib/gerbil.pkg` an environment-owned empty boundary.**  
   `gxpkg` or environment creation could establish it once and exclude it from package manifests/cleaning. This is simpler but introduces shared lifecycle and compatibility concerns.

3. **Continue requiring named package prefixes for published packages.**  
   This is already reliable and aligns with package-manager guidance, but leaves documented empty boundaries unsuitable for installed top-level libraries.

An upstream fix is justified because the guide promises that an empty boundary establishes a logical source hierarchy. It should receive a regression test involving one package compiling an installed package-free dependency. It is not necessary to block sse-gerbil on that fix.

---

## Disposable layout test

Using installed Gerbil `v0.19-dev-31-g4a4d1a30`, four named layouts were compiled into fresh temporary `GERBIL_PATH` environments. A separate package then imported each dependency, was compiled, and was imported again:

```text
:sse/sse       build+consumer-import OK
:jay/sse       build+consumer-import OK
:sse/main      build+consumer-import OK
:sse/http      build+consumer-import OK
```

This establishes technical relocation safety for all four named layouts. It does not make their semantics equally good.

---

## Alternatives and trade-offs

### `:jay/sse` — recommended

**Pros**

- Directly follows Gerbil’s vendor-prefix recommendation.
- No redundant segment.
- No implied sibling transport architecture.
- Collision-resistant for a generic acronym.
- Tested through a compiled consumer.

**Cons**

- Personal ownership is embedded in the import path.
- A future organization transfer may leave an historical namespace.

A durable organization/community prefix would offer the same technical advantages if one exists.

### `:sse/sse` — best owner-neutral fallback

**Pros**

- Stable named package.
- Product namespace is independent of maintainer.
- Repetition is conventional in the sample.
- Tested and already validated by the previous install audit.

**Cons**

- Redundant spelling.
- The globally generic `sse` package prefix has greater collision potential.

### `:sse/http`

**Pros**

- Technically stable.
- Calls attention to the HTTP server integration.

**Cons**

- SSE already denotes an HTTP protocol.
- Suggests sibling transports or adapters not presently planned.
- KISS/YAGNI violation for a three-procedure, one-module package.

### `:sse/main`

**Pros**

- Technically stable.

**Cons**

- Gerbil convention associates `main` with executable entry points.
- Says nothing about the API’s domain.
- Not used as a documented primary library path in the survey.

### `:sse/lib`

**Pros**

- Similar to Gerbil’s generated project layout.
- Honest generic library role.

**Cons**

- Less searchable and descriptive than `sse`.
- Generator convention is primarily a scaffold, not evidence that `lib` is ideal for a published single-module API.

### Exact `:sse`

**Pros**

- Shortest and aesthetically clean.

**Cons**

- Not relocation-safe on current Gerbil v19.
- Requires a Gerbil fix or unsafe shared-marker workaround.
- Saves only one import segment and does not justify delaying publication.

---

## Validation commands

### Focused validation for the recommended layout

Run in a disposable copy after changing the copy to `(package: jay)` and consumer imports to `:jay/sse`:

```sh
T=$(mktemp -d)
cp -a /home/jay/Code/workbench-gerbil/sse-gerbil "$T/sse"
mkdir -p "$T/env/lib" "$T/consumer"

printf '(package: jay)\n' > "$T/sse/gerbil.pkg"
(
  cd "$T/sse"
  GERBIL_PATH="$T/env" ./build.ss
)

printf '(package: consumer)\n' > "$T/consumer/gerbil.pkg"
cat > "$T/consumer/use.ss" <<'EOF'
(import :jay/sse)
(export ok)
(def ok #t)
EOF

(
  cd "$T/consumer"
  GERBIL_PATH="$T/env" gxc -d "$T/env/lib" use.ss
)

GERBIL_PATH="$T/env" gxi -e \
  '(import :consumer/use :jay/sse) (displayln "relocation OK")'
```

The critical part is compiling and re-importing `:consumer/use`; a direct dependency import alone does not expose the empty-boundary bug.

### Full publication validation

On a Gerbil distribution with working `:gerbil/tools/gxtags`:

```sh
T=$(mktemp -d)
cd "$T"
printf '(package: publish-smoke)\n' > gerbil.pkg

gerbil pkg install git.cons.io/jay/gerbil-datastar
gerbil env gxi -e \
  '(import :jay/sse :datastar/http) (displayln "imports OK")'
gerbil pkg retag
```

Then from the installed package environments:

```sh
gerbil test -v 0 ./sse-test.ss
gerbil test -v 0 ./...
gerbil test -v 0 -D datastar-conformance ./http/conformance-test.ss
```

Inspect conformance output rather than relying only on exit status: the prior audit found semantic failures despite `gerbil test` returning zero.

---

## Remaining risks and gaps

- The sample is dominated by Mighty Gerbils and Ober because that reflects the current git.cons.io population; it is not a random sample of every Gerbil package hosted elsewhere.
- Several repositories do not document imports. Their module IDs were inferred from committed boundaries and targets rather than verified by full builds requiring foreign dependencies.
- Auto-discovered build scripts in `gerbil-utils`, `gerbil-poo`, and `gerbil-persist` were recorded by mechanism and source layout rather than executed.
- The installed Gerbil still lacks compiled `:gerbil/tools/gxtags`, causing `gxpkg` installation to fail during retagging. This is independent of module naming and remains a publication blocker.
- Datastar conformance failures documented in the earlier audit are also independent of the naming recommendation.
- Changing the public import path is an API break. SSE and Datastar source, tests, README examples, dependency builds, and stale compiled interfaces must all be updated together when implementation occurs.