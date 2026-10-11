# Oracle review: Tuna web terminal

**Verdict: NOT APPROVED — actionable contract gaps remain.**

## Inherited decisions

- Independent `tuna-web-terminal` package; Tuna core and existing executable remain unchanged.
- One process-wide authoritative Tuna root shared by all tabs, including shared pending prefixes.
- Browser transports bounded raw keyboard facts only; normalization and keymap resolution occur from the dequeue-time root.
- Admission-only `204`; committed state is rendered solely through `/subscribe`.
- Public Datastar `action()` plugin, stock document listener lifecycle, and one page-local FIFO.
- One Tuna subscription per SSE connection, latest-snapshot outer morphs of only `pre#state`, and no heartbeat.
- Runtime stops and drains before HTTP shutdown so subscriptions and completed SSE responses close cleanly.
- No UI beyond the single state `<pre>`.
- Acceptance remains blocked until the active Gerbil runtime includes commit `4531c21b`.

## Diagnosis

The overall architecture is consistent with the research. In particular:

- `read-signals` is compatible with this raw envelope: it parses one bounded strict JSON body, uses string keys rather than interning them, and the underlying JSON reader rejects duplicate keys. It does **not** validate media type, so the draft’s media-type/marker checks before parsing are necessary and correct.
- The FIFO proof is appropriately limited to sequential attempts and successfully acknowledged admissions; it does not claim exactly-once delivery.
- Public Datastar action usage, stock listener cleanup, shared multi-tab prefixes, latest-snapshot subscription handling, fat morphing, no-heartbeat risk, and runtime-before-HTTP shutdown all match the evidence.
- The status mapping, raw-versus-authoritative-state boundary, local-only assets, Gerbil prerequisite, and dumb-terminal/no-extra-UI intent are sound.

## Drift / contradiction check

### High — completion observers have no lifecycle owner

Draft lines 182, 211, 272, and 293 require every accepted completion failure to be observed and logged, but shutdown joins only the Tuna owner and HTTP server. `command-runtime-join!` joins only the runtime thread (`tuna/tuna/lib/runtime.ss:369-372`), not spawned completion waiters.

A waiter thread per accepted request is not strictly bounded by runtime capacity once completions are posted, and untracked waiters can race `shutdown-logging!`, lose required failure logs, or outlive shutdown.

**Required correction:** define a package-owned, tracked completion-observation mechanism. Observation must be registered reliably after acceptance, all observers must be drained/joined before logging shuts down, and observer failures must not affect the already-earned `204`. Preserve runtime-before-HTTP shutdown; add the observer drain explicitly to the unwind order.

### High — atomic dispatcher composition is underspecified relative to the approved keymap contract

Draft line 98 says the dispatcher “propagates” the target outcome, but omits the mandatory composition rules from `plans/tuna-input-keymaps/spec.md:155-163`:

- obtain and validate a proper argument list from the opaque binding specification;
- invoke the live target on a prefix-cleared base;
- let a changed target own its candidate and propagate its result;
- if the target is unchanged but clearing the prefix changed the root, return `state-changed` with that base;
- reject invalid target outcomes;
- preserve the exact prior root and prefix on acquisition or invocation failure.

The API inventory at lines 243-260 also omits the keymap accessors, `invoke-state-transition`, state outcome observers, and the `state-changed`/`state-unchanged` constructors. Those constructors require result values (`runtime.ss:89-107`), which the transition contracts do not specify.

**Required correction:** incorporate the approved algorithm explicitly, including private completion-result values and proper-list argument handling for the fixed no-argument binding. Do not leave “propagates” open to returning `state-unchanged` without committing a cleared prefix.

### Medium — executable and validation staging are not reproducible yet

The validation block builds the host before its local Tuna and Gerbil Datastar foundations and does not prove which compiled packages the host imports. Existing independent Tuna package guidance requires an explicit development environment (`tuna/tuna/README.md:45-56`); a bare host `gerbil build` can resolve stale installed modules.

The contract also leaves unspecified:

- command-runtime capacity;
- executable target/name and fixed loopback listen address/port;
- how tests obtain an ephemeral port without adding public API;
- the exact package test command;
- module provenance for Tuna, Gerbil Datastar, and SSE;
- the pinned browser harness and three-engine provisioning.

Several acceptance cases—`full`, `not-running`, delayed admission, policy replacement, and deliberate transition failure—cannot be induced through the fixed black-box executable.

**Required correction:** define a shared, controlled Gerbil staging environment and build dependencies before the host; verify imported module provenance; set private capacity/listen constants; and partition acceptance into real-executable browser tests versus package-internal fixtures/test-only transitions. No public application API is needed.

### Medium — custom plugin and static-asset distribution are not fully closed

Lines 51, 167, 199, and 319 select separate pinned modules but do not settle:

- the exact HTML module graph and ordering;
- that the plugin ESM imports external `"datastar"` and is loaded exactly once;
- source location, lockfile, build script, and output-freshness check;
- how the executable locates or embeds assets independently of its current working directory.

The official starter evidence supports an import map followed by one plugin module script; importing `"datastar"` loads the mapped pinned module.

**Required correction:** specify the exact script/import-map markup, pinned frontend dependency/tool versions, externalized Datastar import, committed or deterministically generated output verification, and a working-directory-independent asset strategy.

### Low — rendering incorrectly implies revision equals counter

Draft lines 24 and 194 use the same `N` for both values. Policy replacement and prefix-only transitions can increment revision without incrementing the counter.

**Required correction:** use distinct placeholders:

```scheme
(terminal (revision <revision>) (counter <counter>))
```

### Low — pin the one-shot HTTP response seam

The status table is correct, but the public API section omits the actual Gerbil response seam. The contract should direct page/assets/errors and empty `204` through `ResponseHandler-write!` with public `Status` values and proper header alists, including exact `Allow`, HTML/JavaScript content types, and immutable asset caching. Datastar patch-response helpers should not be mistaken for these ordinary responses.

Also define behavior for a `/subscribe` request arriving in the narrow interval after the runtime reaches `stopped` but before `server.stop!`; otherwise it can become an incidental `500`.

## Recommendation

Return the draft for a narrow revision addressing the findings above. No architectural pivot is warranted: preserve the independent package, raw transport, authoritative normalization, CQRS split, FIFO action, one-root/shared-prefix semantics, subscription design, no-heartbeat choice, and one-`pre` UI.

## Risks

- The active dev31 Gerbil runtime still blocks valid completed SSE acceptance.
- Network ambiguity, idle disconnect retention, slow-writer blocking, Input Method Editor limitations, and reserved shortcuts remain correctly documented.
- Test-only control seams must remain package-internal.
- Completion-observer management must not become a second state broadcaster.

## Need from main agent

Revise and resubmit the contract, explicitly settling private runtime/listen constants, completion-observer ownership, dependency staging, and asset/toolchain packaging. No new owner-level product decision is otherwise required.

## Suggested execution prompt

No implementation handoff is warranted. The specification is not yet Oracle-approved.