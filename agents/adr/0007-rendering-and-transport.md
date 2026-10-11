# 7. Server-rendered HTML screens over Datastar; layout belongs to the browser

Status: accepted (2026-10-11); amended after the [capability audit](../research/capability-audit/README.md) (ordinary tabs first-class, layout ownership, input proxy, event identity, "screen" terminology).

## Context

The browser is the primary display, used like a terminal: every user action is sent to the server, and the server sends back the new view. Datastar supports this with command `POST`s and a long-lived server-sent-event stream that morphs HTML into the page ([vendored docs](../reference/datastar/docs.md)). Weevil proved the approach in Racket, including server-side viewport slicing.

The audit found that the server cannot know layout (wrapping, proportional fonts, images, variable line heights), that ordinary browser tabs never deliver some keys (`C-w`, `C-n`, `C-t`), and that composition input, dead keys, mobile keyboards, and screen readers require a focused editable element ([lanes 1, 2, 5](../research/capability-audit/README.md)). The owner requires ordinary browser tabs to remain first-class (remote development) and requires buffers to mix monospace and proportional text, even within one buffer.

Datastar's Rocket (beta) defines web components with typed props, local signals, and events: "props down, events up". It is a candidate for local-only behavior such as scrolling and wrapping.

## Decision

- **Terminology.** One complete rendering of what a browser tab shows is a **screen**. **Frame** keeps its Emacs meaning: a top-level window with its own window tree.
- **Input.** A small Datastar plugin captures keyboard, mouse, paste, composition, and resize events and `POST`s them in order to `/commands`. The server answers `204` on receipt and enqueues the event ([ADR 3](0003-command-loop-and-jobs.md)). Responses never carry UI. Each event carries the client id and a per-client sequence number ([ADR 10](0010-security-clients-and-trust.md)); pointer events also carry the revision of the screen they were computed against.
- **Input proxy.** The page may keep one hidden, focused editable element to receive composition, `beforeinput`, and paste events and to give assistive technology a focus target. It forwards what it receives and clears itself. Buffer text is never edited by the browser.
- **Keys.** Ordinary browser tabs are a first-class client. Key capture is best-effort: keys the browser reserves are unavailable in that client, and users bind other keys. Tuna does not require a special launch mode; app windows or native shells are optional conveniences.
- **Output.** Each client holds one `GET` SSE stream. After the editor loop decides to redisplay, it renders the screen and each client's writer thread sends the newest one as a Datastar element patch (a "fat morph"). A slow client skips intermediate screens; it never blocks the editor.
- **Rendering pipeline.** Editor state → renderer service → SXML → HTML. The `Renderer` is a `std/interface` service, so a terminal renderer can be added later. Node kinds supply their own render procedures.
- **Layout belongs to the browser.** The server decides content and styling, never pixel or cell layout, and the core must not assume a fixed-width grid. Monospace and proportional text may mix within one buffer. Commands that depend on layout (visual-line motion, page scrolling, `current-column` in proportional text, popup placement) obtain layout facts from the client. The mechanism is an open research item, to settle before windows and scrolling are built; candidates are layout facts attached to events as signals, a task suspending to request a measurement, and Rocket components that perform local-only behavior (scrolling, wrapping, perhaps some navigation) from server-supplied props and report results as events.
- **Presentation-only browser state.** Authoritative editor state lives on the server. The browser may own purely presentational state (hover, cursor blink, scroll within already-rendered content, layout) and report what the server needs.
- **Identity.** Rendered elements carry stable node identifiers so pointer events map back to nodes and positions. Popups are anchored to node identifiers with CSS, not computed pixel positions.
- **Client-owned widgets.** Later, node kinds such as terminals, canvases, and document viewers may own a client-side widget with its own data channel, excluded from morphing.
- **HTML.** Semantic elements, CSS custom properties for design tokens, and no CSS class soup ([html-css guide](../guides/html-css.md)). Text is always escaped; only renderer code creates elements.
- **Clients.** Initially every client mirrors the same frame, like attaching to one tmux session. Per-client frames come later ([ADR 10](0010-security-clients-and-trust.md)).

## Consequences

- The browser holds no authoritative state; reconnecting simply receives the current screen.
- Whole-screen morphs are simple but cost bandwidth and render time proportional to visible content. Keydown-to-patched-screen latency is measured from the first prototype; finer-grained patches are an optimization behind the same pipeline.
- Until the layout research is done, screen-relative commands cannot be written correctly; logical-line commands can.

## Alternatives considered

- **Client-side editor component (CodeMirror, Monaco).** Rejected: splits editor state between client and server.
- **Fixed-width cell grid with server-side wrapping.** Rejected by the owner: buffers must mix proportional and monospace text.
- **App window or native shell as the only supported client.** Rejected by the owner: ordinary tabs are needed for remote development.
- **WebSocket protocol with custom diffing.** Rejected for now: Datastar's SSE morphing already works and keeps the client small.
