# Research: Current Datastar release and SSE protocol

## Summary
The authoritative GitHub `releases/latest` endpoint identifies **Datastar v1.0.2** as the latest stable release: published **2026-06-02 15:16:12 UTC**, `prerelease: false`. Its signed annotated tag resolves to commit **`e24f04d43ca4445d662b4a035e5bfe9ed68de57c`**. [Release](https://github.com/starfederation/datastar/releases/tag/v1.0.2) · [tag object](https://api.github.com/repos/starfederation/datastar/git/tags/5cce9fcdda43cb443b4e5e596b67cef903619831) · [commit](https://github.com/starfederation/datastar/commit/e24f04d43ca4445d662b4a035e5bfe9ed68de57c)

The current wire contract is Datastar-over-SSE: `datastar-patch-elements` and `datastar-patch-signals`. `namespace` (`html`/`svg`/`mathml`) and `useViewTransition` are established v1 contract fields; `viewTransitionSelector` is a newly released (v1.0.2) public field, documented and implemented in the tagged client, but not yet represented by the maintained SDK v1 configuration/golden fixtures.

## Findings
1. **Correct stable version and immutable provenance.** GitHub’s latest-release API returns tag `v1.0.2`, non-draft and non-prerelease, published 2026-06-02 15:16:12 UTC. The annotated, verified tag `5cce9fc…` points to verified commit `e24f04d…` (authored 2026-06-02 15:08:42 UTC). Pin source and CDN references to `v1.0.2` (or the commit SHA for immutable source evidence), not an RC. [Latest release API](https://api.github.com/repos/starfederation/datastar/releases/latest) · [release page](https://github.com/starfederation/datastar/releases/tag/v1.0.2) · [tag → commit](https://api.github.com/repos/starfederation/datastar/git/tags/5cce9fcdda43cb443b4e5e596b67cef903619831)

2. **Current element-patch event contract.** The official reference specifies an SSE event `event: datastar-patch-elements`, terminated as an SSE event (blank line), with `data:` lines. Fields are: `elements` (markup; required for a content patch), `selector` (optional for `outer`/`replace`), `mode` (`outer` default; also `inner`, `replace`, `prepend`, `append`, `before`, `after`, `remove`), `namespace` (`html` default, `svg`, `mathml`), `useViewTransition` (`false` default), and `viewTransitionSelector` (`document` default). The reference gives an example using both view-transition lines. [Official SSE reference](https://data-star.dev/reference/sse_events) · [tagged client parser/validator](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/library/src/plugins/watchers/patchElements.ts)

3. **Current signal-patch event contract.** `event: datastar-patch-signals` carries `data: signals <data-signals-compatible object>` and optionally `data: onlyIfMissing true`; omitted `onlyIfMissing` updates existing signals. Setting a signal to `null` removes it. Standard SSE `id:` and `retry:` lines may accompany either Datastar event; maintained golden output shows their placement before Datastar `data:` lines. [Official SSE reference](https://data-star.dev/reference/sse_events#datastar-patch-signals) · [golden wire fixture](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/tests/golden/get/patchElementsWithAllOptions/output.txt)

4. **Namespace is stable.** `namespace` was introduced in `v1.0.0-RC.7` for SVG/MathML, then shipped in final 1.0 and remains documented and validated in v1.0.2. The maintained `datastar-sdk-config-v1.json` defines `Namespace` as exactly `html`, `svg`, and `mathml`, default `html`; the tagged client rejects values outside that set. Treat it as stable v1 protocol surface. [RC.7 release note](https://github.com/starfederation/datastar/releases/tag/v1.0.0-RC.7) · [v1 SDK config](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/datastar-sdk-config-v1.json) · [client validation](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/library/src/plugins/watchers/patchElements.ts#L17-L66)

5. **View-transition fields: released, with one fixture lag.** `useViewTransition` is an established v1 field: its default is `false` in the SDK config and the official golden fixture serializes `data: useViewTransition true`. In v1.0.2, the release explicitly adds `viewTransitionSelector`; the tagged client reads it only as a string, defaults to the document element when absent or unmatched, and only starts a transition if `useViewTransition` is exactly string `true` and the browser supports the API. Therefore both names are public stable-release contract, but **only `useViewTransition` has present SDK v1 config/golden coverage; `viewTransitionSelector` does not**. This is a conformance-fixture gap, not evidence that the released field is experimental. [v1.0.2 release note](https://github.com/starfederation/datastar/releases/tag/v1.0.2) · [official reference](https://data-star.dev/reference/sse_events#datastar-patch-elements) · [tagged implementation](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/library/src/plugins/watchers/patchElements.ts#L38-L76) · [fixture input](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/tests/golden/get/patchElementsWithAllOptions/input.json)

6. **Why RC.7 appeared, and why it is obsolete for current guidance.** `v1.0.0-RC.7` is a real signed historical tag at commit `904295865136b82a13eae2ba825d50693fa8c42e`, published **2025-12-16 16:55:19 UTC**; its release note introduced `namespace`. Its name has the SemVer prerelease identifier `-RC.7` even though the GitHub release record happened to mark `prerelease: false`. It was superseded by final **v1.0.0**, published **2026-04-16 16:40:39 UTC**, and then v1.0.2. Earlier research likely surfaced RC.7 because it was the release that introduced namespace or because dated search results ranked it; it must not be treated as the current version or current complete protocol reference. [RC.7 release](https://github.com/starfederation/datastar/releases/tag/v1.0.0-RC.7) · [RC.7 tag → commit](https://api.github.com/repos/starfederation/datastar/git/tags/bb49b257787310e396f511f5912fdc6180ab4a60) · [final 1.0.0 release](https://github.com/starfederation/datastar/releases/tag/v1.0.0)

7. **Maintained SDK conformance evidence and limitation.** The first-party repository carries `sdk/tests`, a Go runner plus embedded golden GET/POST fixtures. Its README says it validates SDK implementations by comparing `input.json` requests with expected SSE `output.txt`, including element/signal patches and formatting. The v1 config recognizes two core event types and datalines through `namespace`, but not the selector added in v1.0.2. An SDK that needs v1.0.2 selector support should add/verify a golden case before claiming fixture-level conformance for that new field. [SDK test-suite README](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/tests/README.md) · [all-options golden fixture](https://github.com/starfederation/datastar/tree/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/tests/golden/get/patchElementsWithAllOptions) · [SDK config](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/datastar-sdk-config-v1.json)

## Sources
- Kept: [Datastar v1.0.2 release](https://github.com/starfederation/datastar/releases/tag/v1.0.2) — authoritative latest stable version/date and release note for `viewTransitionSelector`.
- Kept: [GitHub latest-release API](https://api.github.com/repos/starfederation/datastar/releases/latest) — machine-readable `prerelease: false` and publication timestamp.
- Kept: [v1.0.2 signed tag object](https://api.github.com/repos/starfederation/datastar/git/tags/5cce9fcdda43cb443b4e5e596b67cef903619831) — exact verified tag-to-commit resolution.
- Kept: [Official SSE Events reference](https://data-star.dev/reference/sse_events) — normative field names, defaults, and examples.
- Kept: [v1.0.2 patch-elements source](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/library/src/plugins/watchers/patchElements.ts) — pinned implementation behavior and accepted namespace set.
- Kept: [v1 SDK config](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/datastar-sdk-config-v1.json) and [SDK suite](https://github.com/starfederation/datastar/blob/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/sdk/tests/README.md) — maintained conformance scope.
- Kept: [RC.7 release](https://github.com/starfederation/datastar/releases/tag/v1.0.0-RC.7) and [v1.0.0 final release](https://github.com/starfederation/datastar/releases/tag/v1.0.0) — historical correction and supersession evidence.
- Dropped: search-result commentary and third-party SDK documentation — not needed where official release, docs, source, and fixtures give direct evidence.

## Gaps
- The maintained SDK v1 configuration and visible golden cases do not yet include `viewTransitionSelector`; release notes, official docs, and v1.0.2 client source do. Add a first-party golden fixture if cross-SDK selector serialization needs automated conformance proof.
- Browser support for the underlying View Transition API is outside Datastar’s wire contract; the client conditionally falls back to a normal patch when unsupported.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Research artifact written at .pi-subagents/artifacts/outputs/efd0e8ae-c259-4d13-b902-78f16bb92403/research/12-current-datastar-release-and-protocol.md; findings include exact version/date, tag and commit, protocol fields, stable-status assessment, and source URLs."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/efd0e8ae-c259-4d13-b902-78f16bb92403/research/12-current-datastar-release-and-protocol.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "Authoritative GitHub API and official-doc/source retrieval via web research",
      "result": "passed",
      "summary": "Confirmed v1.0.2 latest stable metadata, signed tag-to-commit resolution, current docs, source, SDK config, and golden fixtures."
    }
  ],
  "validationOutput": [
    "Latest release: v1.0.2, published 2026-06-02T15:16:12Z, prerelease=false.",
    "Tag v1.0.2 resolves to commit e24f04d43ca4445d662b4a035e5bfe9ed68de57c.",
    "SDK v1 fixtures cover namespace and useViewTransition but not viewTransitionSelector."
  ],
  "residualRisks": [
    "viewTransitionSelector is released and documented in v1.0.2 but lacks maintained SDK v1 configuration/golden-fixture coverage.",
    "View Transition execution remains browser-capability-dependent; unsupported clients perform a normal patch."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added the requested research artifact only; no project source or tests modified.",
  "reviewFindings": [
    "no blockers: primary release metadata, official documentation, tagged source, and maintained fixtures agree on the core contract.",
    "medium: SDK conformance fixtures lag the v1.0.2 viewTransitionSelector field."
  ],
  "manualNotes": "RC.7 was a historical signed release from 2025-12-16 that introduced namespace, but final v1.0.0 (2026-04-16) and v1.0.2 supersede it."
}
```