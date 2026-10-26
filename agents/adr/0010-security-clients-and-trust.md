# 10. Loopback access and the trust boundary

Status: accepted (2026-10-11); amended 2026-10-14 by the owner-approved [input brief](../../docs/briefs/2026-10-input-without-waiting.md): remove launch-token authentication and client identity; assume one tab. Amended 2026-10-22 by [ADR 16](0016-several-tabs-mirror-one-editor.md): a client identity returns, as a tab id the server makes when it serves the page; still no token, cookie or sign-in. Amended 2026-10-23 (owner): the accepted names are a list, not only `127.0.0.1:PORT`; see Header checks.

## Context

`POST /commands` runs editor commands, and plugins are trusted code with the user's privileges ([ADR 2](0002-plugins-contexts-and-services.md)). Reaching Tuna therefore gives the same power as the user's shell. The owner wants a plain local URL, without sign-in, launch tokens, or session cookies. Protection from foreign web pages remains required.

## Decision

- **Binding.** The web plugin listens on `127.0.0.1`. *2026-10-26 (owner):* it may also listen on one more address for a reverse proxy (`listen-also`, for example Docker's bridge address for Caddy with Authelia in front); requests from any peer that is not loopback must then carry a `Tuna-Proxy-Secret` header equal to the secret in `proxy-secret-file` (mode 600, at least 16 characters, compared in constant time), so other containers on the bridge cannot reach Tuna. The two options are required together.
- **Header checks.** Every route rejects a `Host` that is not an accepted name, or an `Origin` header, when present, that is not `http://` or `https://` followed by an accepted name. The accepted names are `127.0.0.1:PORT`, `localhost:PORT`, and the names in the web plugin's `hosts:` option (for example the name `tailscale serve` gives a machine, which forwards HTTPS to this port). This keeps foreign web pages (their Origin) and DNS rebinding (its Host) outside the boundary. *2026-10-23 (owner):* accepting only `127.0.0.1:PORT` refused `http://localhost:PORT` and any HTTPS front end, which was too narrow; adding a name extends trust to whoever can reach it, as the binding already trusts local users.
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
