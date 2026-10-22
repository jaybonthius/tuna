# 10. Loopback access and the trust boundary

Status: accepted (2026-10-11); amended 2026-10-14 by the owner-approved [input brief](../../docs/briefs/2026-10-input-without-waiting.md): remove launch-token authentication and client identity; assume one tab. Amended 2026-10-22 by [ADR 16](0016-several-tabs-mirror-one-editor.md): a client identity returns, as a tab id the server makes when it serves the page; still no token, cookie or sign-in.

## Context

`POST /commands` runs editor commands, and plugins are trusted code with the user's privileges ([ADR 2](0002-plugins-contexts-and-services.md)). Reaching Tuna therefore gives the same power as the user's shell. The owner wants a plain local URL, without sign-in, launch tokens, or session cookies. Protection from foreign web pages remains required.

## Decision

- **Binding.** The web plugin listens only on `127.0.0.1`.
- **Header checks.** Every route rejects a `Host` other than Tuna's `127.0.0.1:PORT`, or an `Origin` header, when present, other than `http://127.0.0.1:PORT`. This keeps foreign web pages and DNS rebinding outside the boundary.
- **No authentication.** Tuna prints `http://127.0.0.1:PORT/`. There is no token, cookie exchange, or launch-secret generation. Any local process or local user able to reach that port can control Tuna; this is accepted by the owner.
- **Input numbering, not client identity.** Keys and clicks carry a page-load sequence number starting at 1 ([ADR 7](0007-rendering-and-transport.md)). No client id or `sessionStorage` is needed: the old id was recorded but never used. Opening the screen stream resets the server's numbering. One tab is assumed; multiple-tab coordination and collaboration are outside this decision.

## Consequences

- Opening Tuna requires only the plain URL it prints.
- Loopback binding and Host/Origin checks must not be removed along with authentication.
- Every command request passing those checks gets `204`, even if the item is rejected; rejection is logged, not shown in the editor.

## Alternatives considered

- **Per-launch token exchanged for a session cookie.** The original decision, replaced by the owner's simpler local-access model.
- **Rely on loopback binding alone.** Rejected: foreign web pages and DNS rebinding must still be blocked with header checks.
- **Sandbox plugins.** Still rejected (ADR 2); plugins remain trusted code.
