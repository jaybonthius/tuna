# Idea: modes per node and per region

**Status:** desired (owner, 2026-10-24), not scheduled in detail; tier 1 in the [roadmap](../roadmap.md). Needs a brief before building.

Emacs gives a buffer exactly one major mode, so a file mixing languages (JavaScript and CSS inside HTML, code blocks in Markdown) needs third-party packages such as Polymode or MMM, which are known to be fragile. Tuna can make this a built-in case, because its buffers are already trees of nodes and its texts already carry ranges that move with edits.

- **Modes attach to a node or to a region of text.** A Markdown code block that is its own node carries its mode; in an HTML file, the `<script>` contents are a region in JavaScript mode and the `<style>` contents a region in CSS mode.
- **The mode at the cursor decides** keys, settings and commands, so moving into the `<script>` switches you to JavaScript behaviour.
- **Highlighting is per region:** each region is highlighted by its own grammar; tree-sitter injections can report where the embedded regions are.
- **Language servers are per region:** each region's text goes to its own server as a separate virtual document, with positions mapped both ways, so diagnostics, completion and go-to-definition work inside the `<script>` as in a JavaScript file.
- **A language plugin only says where the regions are;** the modes system does the rest. The tooling must make writing such a plugin straightforward even if the first version ships without one.

Open questions for the brief: what a mode owns (keymaps, settings, highlighting, indentation, language server); how minor modes combine with region modes; how regions nest; how the status line shows the mode at the cursor.
