# Stage 3 seam recommendation

**Historical proposal, not an approved design.** The later compiled preservation check found the slot-only factory insufficient: Input-only wrapping hides Keys operations; Messages-only wrapping hides EchoArea operations. A hand-written complete-interface wrapper passes, but it needs more metadata than the slot declaration alone. The investigator proposes an explicit factory at provider registration; this is not approved or implemented, and the work is paused after owner concern. Corrected evidence/probes: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage3/seam-note.md` (preservation appendix) and its `service-preservation/` sibling. Review against Emacs's `add-function` place model before accepting a provider-wide wrapper design. The older command control identifiers below are also historical; current keyword protocol is in `stage-3a.md`.

**Use use-site command routing and declaration-generated typed service decorators.** No demonstrated blocker. Predicate-only service declarations need explicit metadata; documented reflection cannot recover signatures. This note authorizes no implementation.

**O** = observed; **D** = documented; **P** = proposed. Tuna: `8acd176`. Installed Gerbil: `v0.19-dev-63-g1cfb032c`; Gambit: `v4.9.8-19-gea114fc3`. Installed `core/contract.ss`, `std/interface.ss`, and cited interface documentation match commit `1cfb032c` byte-for-byte. `G:` below denotes `/home/jay/Code/workbench-gerbil/gerbil/`.

## 1. One form without a prelude→commands dependency

**P:** Keep kind/source/callback normalization in `tuna/prelude.ss:178–199`. For `(command NAME)`, generate **`command-advice-target` in the target head's use-site context**: `(stx-identifier #'tag "command-advice-target")`. Emit `(command-advice-target add ctx 'NAME …)`. The commands contract exports that routing macro; `add`, `remove`, and `inspect` expand hygienically to Commands operations. `unadvise!` and inspection use the latter routes. Require the contract import; do not discover handlers at runtime or maintain a transformer registry.

**D/O:** `stx-identifier` preserves its argument's context (`G:doc/reference/gerbil/expander/identifiers.md:49–57`). The compiled scratch probe proves all three routes without the routing module importing commands. This avoids clobbering **`command`, already the record type/constructor** (`plugins/commands/contract.ss:5–18`). Function targets retain `prelude.ss:168–176`; service syntax calls the shared adapter with the service value and quoted operation.

A uniform inspection API should rename `function-advice`/`function-advice-info` to target-neutral names and update consumers, including describe-advice, together; no compatibility aliases. Keep `advised-functions` genuinely function-only; command/service enumeration follows their state owners.

## 2. Service signatures and typed decorators

**D:** `interface` creates syntax metadata and facades (`G:doc/reference/std/interface.md:325–337`), but documented runtime reflection returns method **names**, not signatures (`:403–408`). **O:** signature accessors exist in `G:src/gerbil/core/contract.ss:30–92`; their exported layout is not a documented reflection contract. Do not inspect those objects.

**P:** A small service-definition form consumes interface signatures once, emitting ordinary `interface`, typed decorator class/`implement`, a private factory, and `new-service` carrying that factory as narrow metadata. The factory takes the base interface and an operation-composition function; all composition happens on mutation. Service values remain ordinary objects, including when aliased or passed as expressions. Illustrative, not existing API:

```scheme
(defservice store-service 'store Store
  tier: 'live doc: "Persistent text."
  (replace (version : :t) (start : :fixnum)
           (end : :fixnum) (text : :string)) => :t)
(advise! ctx (service store-service replace) 'forward
  around: (lambda (original . args) (apply original args)))
```

Generate ordinary `implement Store DecoratedStore` and `Store-replace` calls. Gerbil attaches method signatures itself (`G:src/std/interface.ss:29–42`; `G:src/gerbil/core/contract.ss:2716–2748`). Never fabricate private `namespace::method` names (`:2732–2733`). Preserve declaration-site types and optional/keyword/rest forwarding.

**Cover existing mixins:** Keys→Input (`plugins/keys/contract.ss:153`), EchoArea→Messages (`plugins/echo-area/contract.ss:16`). Publish the declaration form's own quoted signature metadata; export the two base companions through their facade/contract. Derived declarations consume that metadata, not Gerbil internals. Foreign interfaces without it need explicit signatures. The brief's text-store `insert!` is stale: the operation is **`replace`** (`plugins/text-store/contract.ss:14–36`).

The generic declaration generator belongs with service-definition machinery, exported by the kernel facade: kernel modules cannot import `tuna/lib` (`tuna/tests/unit/boundary-test.ss:73–80,765–768`). Decorators are emitted in declaring contracts, including kernel-owned Input/Display/Messages. This generic kernel growth needs the planned ADR 12 amendment; composition policy stays in the library.

**O:** Compiled typed decoration works. Initial probe return validation failed because `:-` trusts arbitrary callback output; checked `:` repaired it. Do not promise dynamic validation from an unchecked assertion. Nullable-return limitations remain deferred.

## 3. Exact cache and execution boundaries

**P:** Keep `kernel.providers` as the only provider table. Add per-kernel, per-service-slot decoration state: opaque library composition state, builder, effective view. Expose a narrow slot-state/rebuild seam, not a kernel identity query. Rebuild on advice/rank/provider mutation. With no provider, cache `#f` but retain live advisors' records; with no advice, return the **exact raw provider**.

Change `tuna/kernel/plugins.ss:377–380` to cache that effective view. Leave warm `service-provider`/typed dispatch (`:382–400`) unchanged. Provider install/removal (`:402–417`) rebuilds from raw entries, never yesterday's wrapper. Advice changes do not change provider entries, emit `service-changed-hook`, call settle, or restart dependents. Dependency/provenance queries still read raw providers (`:420–433,611–625`). Ordinary swaps retain existing restart semantics. Store decoration state in `tuna/kernel/state.ss:20–34`, not the service object's last-kernel cache. Kernel imports no advice library.

**Limits:** interception covers newly resolved service-boundary calls, not provider self-calls. Saved base interfaces remain unadvised; saved decorated interfaces may retain old providers after swaps. Interface shells cache methods (`G:doc/reference/std/interface.md:14–22`; `G:src/gerbil/runtime/interface.ss:96–134,204–215`). Universal interception would need forbidden cache mutation or permanent indirection. Service advice remains outside function advice.

**Commands:** registry-owned advice survives by **name**, independently of removable definitions. Recompose each live definition's stored effective procedure, including shadowed entries that cleanup may expose. Keep `invoke!` lookup/call unchanged (`plugins/commands/plugin.ss:17–38`) and preserve original entry provenance. Move the task-owner/retiring-task envelope from `plugins/commands/contract.ss:41–56` into registry installation so advice runs **inside** it; activation/hooks remain outermost. Update the toy provider. Keys already calls this seam (`plugins/keys/plugin.ss:196–201`). Target-plugin disable/re-enable retains other owners' advice; replacing Commands itself creates a new registry.

## 4. Nonoverlapping implementation stages

| Owner | Files, approximate change, focused proof |
|---|---|
| **Shared first** | `tuna/lib/advice.ss`, `tuna/prelude.ss`, `tuna/boot.ss`, their tests/build entry. Extract reusable ownership/order/composition (`advice.ss:35–123`); routing, neutral inspection, general rank refresh (`boot.ss:874–892`). ~100–200 lines plus tests: function regressions, three routes, missing import, command type coexistence, retained-owner reorder. |
| **Commands** | `plugins/commands/{contract,plugin}.ss`, tests/support only. ~120–220 lines plus tests: ten shared kinds, replacement/absence/re-enable, two-owner cleanup, provenance, nested hooks/identity, suspended-command cancellation, unchanged unadvised path. |
| **Services** | Kernel facade/state/service modules, generic declaration module, contract conversions, service tests. ~200–350 generic lines plus mechanical conversions/tests: typed compiled clients, mixins, two operations/owners, raw-provider restoration, absence/reinstall/swap, no advice-triggered restart/events, captured-handle limits, unchanged unadvised path. |

Freeze the shared seam before target work. Serialize service conversion of the Commands contract **after** its writer finishes; do not assign concurrent edits there. Integrate inspection afterward. Measure actual unadvised command/service paths; this probe supplies no timing result. No durable plan or repository implementation was written.
