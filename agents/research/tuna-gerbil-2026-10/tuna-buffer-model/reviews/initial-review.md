## Review

**Proposal verdict: revise two contracts before acceptance.** The overall ownership and scope fit the owner's decisions; neither correction requires another backend, independent views, native browser editing, or immediate IME/recovery.

### Correct

- Structure, identity and disposal are explicit; logical buffers own ordinary text resources without exposing gap storage (§§2–6, `spec.md:30–135`). Shared point/mark/focus, restrictions, traversal and cross-leaf selection remain model state (§§3, 8–9).
- Multi-leaf preparation/rollback, semantic undo/redo, separate logical/file modification and save checkpoints are covered (§§13–16, `spec.md:234–290`). File coding, aliases, external conflicts and symlink/hard-link limits are stated rather than falsely guaranteed.
- Target-neutral node rendering, HTML source maps, escaping and sparse tokens are specified (§§18–19, `spec.md:296–318`). M3 requires visible properties/overlays in the first usable editor (`spec.md:384–386`). Server-owned input/rendering, mirrored navigation, and deferred composition/recovery match the owner requirements.

### Findings — fix before accepting the proposal

1. **P1 — Overlay relocation lacks a rule for crossed endpoints.** §11 (`spec.md:212–214`) permits non-evaporating range overlays and specifies start-after/end-before affinities, while §8 (`spec.md:165`) maps an anchor consumed by replacement to opposite replacement boundaries according to affinity. For a non-evaporating overlay `[1,2)`, replacing `[0,3)` with two code points maps its start to **2** and end to **0**. The instruction not to reverse endpoints does not define where this surviving overlay collapses. A zero-width overlay with opposing affinities has the same problem on insertion. This affects the rich-overlay contract required for the first usable editor. **Smallest fix:** specify deterministic range normalization/collapse and zero-width relocation policies layered above independent anchor mapping; add these exact cases to §24. No interval-tree redesign is needed.

2. **P1 — A fresh projection is not a command-outcome fence.** §20 (`spec.md:332`) allows destructive input to resume after an uncertain POST outcome and a fresh projection; §21 (`spec.md:336–338`) supplies current/coalesced committed projections, not proof that earlier input has finished or cannot arrive later. The preserved admission-only protocol acknowledges before enqueue (`tuna/tuna/server.ss:88–90`). Repro ordering: an uncertain key intent is delayed/pending; resynchronization returns revision R; input resumes; the earlier intent subsequently executes against the then-current shared target under §14 (`spec.md:254`). Revision R therefore cannot establish that uncertainty has ended. **Smallest fix:** define owner-ordered resynchronization with admission fencing for pre-resynchronization intents, or keep destructive input paused until their disposition is established. This does not require automatic replay, persistent deduplication, or browser-tab navigation state.

### Optional future work and validation limits

IME/dead keys/mobile acquisition, recovery, extra codecs and a terminal renderer can remain deferred. The HTML-only clipboard/accessibility/morph experiments and Gerbil interruption tests already required by M0 remain implementation risks, not additional proposal findings. No builds, browser experiments, shell/Git commands, or repository edits were performed. The supplied checkout revision was not independently verified.

- **Merge verdict: BLOCK** on proposal acceptance until the two contracts above are resolved; implementation remains unauthorized.