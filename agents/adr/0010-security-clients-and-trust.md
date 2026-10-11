# 10. Authenticated clients, client identity, and the trust boundary

Status: accepted (2026-10-11), from the [capability audit](../research/capability-audit/README.md) (lane 5).

## Context

`POST /commands` runs editor commands, and plugins are trusted code with the user's privileges ([ADR 2](0002-plugins-contexts-and-services.md)), so anything that can send commands can run shell commands as the user. An unauthenticated localhost server is reachable from any web page through cross-site requests and DNS rebinding, and from other local users. The owner requires ordinary browser tabs to work, including for remote development.

## Decision

- **Trust boundary.** An authenticated client has the same power as the user's shell. Plugins are trusted.
- **Binding.** Tuna listens on loopback by default. Remote use goes through an SSH tunnel or an explicitly configured listener behind TLS; the same authentication applies either way.
- **Authentication.** Each launch creates a random token. The launch URL carries it once; the server exchanges it for an `HttpOnly`, `SameSite=Strict` cookie, and every route (`/`, `/commands`, the SSE stream, assets that reveal state) requires that cookie. Requests whose `Host` is not the configured host, or whose `Origin` is present and different, are rejected.
- **Client identity.** Each browser tab picks a random client id (kept in `sessionStorage`, which is per tab) and sends it with every event, together with a per-client sequence number ([ADR 7](0007-rendering-and-transport.md)). The server records both with each input event.
- **Clients and frames.** Initially all clients mirror one frame and share one input session ([ADR 8](0008-input-keymaps-and-command-composition.md)). Per-client frames, each with its own selected window and input session (an `emacsclient -c` analogue), are planned and need no change to the event format.
- **Collaboration** between different people is a non-goal for now. Change records carry the client id so it is not precluded.

## Consequences

- The keyboard plugin and server must implement the token exchange and header checks from the first prototype.
- Opening Tuna requires the launch URL (or an already authenticated cookie); the `tuna` command prints or opens it.

## Alternatives considered

- **Rely on loopback binding alone.** Rejected: DNS rebinding and other local users defeat it.
- **Sandboxed plugins to limit damage.** Rejected for now (ADR 2); the boundary is who can reach Tuna, not what plugins can do.
