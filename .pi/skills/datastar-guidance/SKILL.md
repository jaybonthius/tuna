---
name: datastar-guidance
description: Settle a Tuna question about Datastar commands, SSE streams, fat morphs, signals, or the browser input plugin without growing client-side state. Use before changing the browser transport or frontend.
---

# Datastar guidance

Read [ADR 7](../../../agents/adr/0007-rendering-and-transport.md) first. Keep its pattern unless a concrete behavior shows it failing.

## Project pattern

- The server owns all editor state. The browser is a terminal: it captures events and displays frames.
- Events are `POST`ed in order to `/commands`; the server answers `204` on receipt. Responses never carry UI.
- Each connection holds one `GET` SSE stream that receives whole-frame element patches. Writers send the newest frame and skip stale ones.
- Signals carry only transient browser facts (viewport size, composition state) and are untrusted input.
- Handwritten JavaScript is limited to the input plugin in `frontend/`, compiled by esbuild into `web/`. Rocket components for local-only behavior (scrolling, wrapping) are under research; adding them needs an ADR.
- Every route requires the launch-token cookie and Host/Origin checks (ADR 10). Events carry a client id and sequence number.

## When unsure

1. Read the vendored documentation in `agents/reference/datastar/docs.md` (includes Rocket).
2. Check the Gerbil SDK: `/home/jay/Code/workbench-gerbil/datastar-gerbil` (`:gerbil-datastar/http`) and its README.
3. Check `agents/research/workbench-gerbil/12-current-datastar-release-and-protocol.md` and the SSE fan-out/disconnect notes beside it.
4. Check Datastar source and docs in `/home/jay/Code/datastar/datastar` (may be older than the v1.0.2 bundle in `web/`).
5. For community answers, read `/home/jay/Code/datastar-discord-export/AGENTS.md`, then search that export. Never run a live Discord export.

Return the smallest recommendation that resolves the behavior, and name any genuine owner decision.
