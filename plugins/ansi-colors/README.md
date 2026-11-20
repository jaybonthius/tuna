# ansi-colors

Reads the styles programs write with SGR control sequences, `ESC [ … m`, and draws them: the sixteen colours as faces, colours 16 to 255 and direct colours, bold, faint, italic, the underline styles, inverse, strikethrough and overline. Runs pass a program's output through `ansi-colors:filter`, and the terminal draws libghostty's cell styles with `ansi-colors:span-value`, so one theme setting colours both.
