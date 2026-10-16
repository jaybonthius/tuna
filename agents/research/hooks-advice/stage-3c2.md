# Described providers and the effective cache

Merged `50d457a` (2026-10-16), containing worker `b2a4d52` and parent metadata fix `a4ef2e5`. Parent reviewed source/placement/migrations, added the lookup regression, and ran capped full `make test` on final source: passed (47 Gerbil modules, 12 frontend tests, demo check). ADR12 records both new exports and private fields. Kernel/production net +68 lines; other production edits mechanically supply required descriptions.

## Exact library handoff

`(context-provide! ctx svc raw view: CompleteType-service-view)` requires the registration's complete description. A private raw+description binding stays in the existing single provider entry. Raw validation, owner/provenance/dependencies/receipts and raw lifecycle payloads are unchanged.

`(service-decoration-state! svc initialize)` gets/creates opaque state in the current service registry, once per named slot. `initialize` receives `(install! builder-or-#f)` and returns any opaque value, including #f. Retain that capability: it is bound to the actual slot/kernel and remains correct even when another kernel is current. A builder receives `(raw registration-description)` and returns the effective interface. Call install! again after policy changes to rebuild; install #f to restore exact raw identity. No provider means effective #f without dropping opaque state or pending decoration. Initialization failure publishes no opaque/decorated state; later build failure preserves the prior decoration/cache.

`service-decoration-states` returns initialized opaque values in the current registry only; enumeration creates nothing. Library code must recognize its own state type. There is no kernel identity token, arbitrary-key extension registry or second provider table. The existing kernel-services table holds private slot objects; warm cached dispatch is unchanged.

When using `(service-view-build description)`, compose each supplied qualified base separately with the operation's shared records; compose can repeat the same op symbol. Rebuild from RAW with the NEW registration's description, never an old wrapper. Decoration changes emit no provider events/restarts/receipt additions. Raw/decorated captured handles retain their snapshot limits.

## Review, evidence and limits

Parent reproduced a metadata bug: getting state through an old same-name service object changed the current provider's reported doc/tier. Registration now owns metadata updates; state lookup only creates a missing slot. Parent red/green logs: `parent-cache-metadata-{probe,fixed}.log`; contextual syntax logs and `parent-service-cache-make-test.log` beside them in `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage3/`.

Worker full test preceded its final two-line metadata refresh adjustment; its final focused run covered that adjustment. The independent parent full run covers ALL final source including the later lookup fix. Detailed worker failures/migrations/benchmarks are in `service-cache-report.md` and `service-cache-evidence/` in that scratch directory.

Compiled unadvised lookup+typed dispatch medians were 53.942→52.109ns across nine sequential unpinned samples; not a reliable speedup or zero-cost proof. The parent fix changes only metadata mutation, not measured warm code. Kernel has no advice policy; library registration/routing and broader inspection remain next.
