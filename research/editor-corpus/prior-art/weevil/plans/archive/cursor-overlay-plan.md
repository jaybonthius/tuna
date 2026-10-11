# Line-Based Cursor Rendering Plan

## Problem

The original renderer used one giant `<pre><code>` for the whole buffer
and inserted the cursor into that global visible text stream. That made
cursor movement reshape the visible text DOM and introduced layout
jitter.

The problem is the render model, not font features.

## Decision

Render the buffer as logical lines and render the cursor as a zero-width
marker inside the active line.

No overlay layer. No cursor-positioning JavaScript. No hidden full-buffer
prefix. No server line/column CSS math.

## DOM shape

```html
<div id="editor" class="editor" role="textbox">
  <div class="editor__buffer">
    <div class="editor__line">first line</div>
    <div class="editor__line editor__line--active">
      abc<span class="editor__cursor" aria-hidden="true"></span>def
    </div>
    <div class="editor__line">last line</div>
  </div>
</div>
```

The cursor marker is part of the active line DOM, but it consumes zero
width and draws the caret with a pseudo-element. It is not a separate
overlay layer and it is not inserted into one giant whole-buffer text
flow.

## Why line-based rendering

Line wrappers solve vertical placement naturally: the cursor is in the
line where point lives.

Inline zero-width cursor marker solves horizontal placement naturally:
the marker sits after the preceding inline content in that line.

This avoids:

- duplicating the whole buffer prefix
- client-side geometry measurement
- `1ch` coordinate math
- per-segment cursor metadata
- cursor overlay infrastructure
- giant `<pre><code>` churn

It also prepares for line numbers, gutters, diagnostics, viewported
rendering, and active-line styling.

## Renderer contract

In `weevil/private/web/render.rkt`:

1. Convert the server-owned buffer projection into logical line xexprs.
2. Preserve style spans when splitting at newlines.
3. Insert exactly one cursor marker at `point-byte`.
4. Represent empty and trailing lines with `.editor__line` elements.
5. Do not render a whole-buffer `<pre><code>` wrapper.
6. Do not create overlay nodes/classes.
7. Do not add cursor-positioning metadata.

The visible buffer text is still a server-rendered projection. The DOM is
not editor state.

## CSS contract

`.editor__buffer` owns the editor font and color.

`.editor__line` preserves whitespace and wrapping:

```css
.editor__line {
  min-height: 1.5em;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
```

`.editor__cursor` is a zero-width inline marker:

```css
.editor__cursor {
  position: relative;
  display: inline-block;
  width: 0;
  margin: 0;
  padding: 0;
}

.editor__cursor::before {
  content: "";
  position: absolute;
  inset-inline-start: 0;
  width: 0.09em;
  background: var(--secondary-5, #fe9350);
}
```

Do not disable ligatures or kerning as a cursor fix.

## Scope

First implementation includes:

- line-based buffer DOM
- one inline zero-width cursor marker
- empty/trailing line rendering
- Unicode-safe point placement using existing byte-boundary helpers
- renderer tests for line/cursor invariants

First implementation does not include:

- selection rendering
- mouse hit-testing
- IME
- viewport virtualization
- bidi caret policy
- native browser selection integration
- cursor-positioning JavaScript
- overlay cursor layer

## Tests

Tests should assert:

- rendered editor no longer contains a giant `<pre><code>` buffer
- `.editor__buffer` contains `.editor__line` children
- exactly one `.editor__cursor` exists
- cursor is inside `.editor__line--active`
- multiline, empty-line, trailing-newline, and multibyte cursor positions
  render correctly
- text reconstruction from lines matches source buffer
- no overlay cursor classes or cursor-positioning JS are required

## Acceptance criteria

- Moving point left/right does not shift visible letters.
- Cursor is rendered with server HTML/CSS only.
- No giant `<pre><code>` buffer remains.
- No overlay layer is introduced.
- No JavaScript cursor-positioning file exists or is loaded.
- Ligatures and kerning remain enabled.
- Server remains the source of truth for text and point.
