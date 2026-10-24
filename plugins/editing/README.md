# editing

Editing text, as Emacs's built-in commands do: typing, deleting, moving by characters and lines and to either end, and undo; the mark and the region (`C-SPC`, `C-x C-x`, shift selection); the kill ring (`C-w`, `M-w`, `C-y`, `M-y`, and the browser's paste key); and clicking and dragging in text (click, drag, double- and triple-click, shift-click).

The contract gives other plugins the region (`region-active?`, `region-beginning`, `region-end`, `deactivate-mark!`, `set-temporary-region!`) and the kill ring (`kill-new`, `current-kill`, and `kill-new-hook`, where the web transport copies to the clipboard), through `editing-service`.

Settings: `delete-selection` (off; on, typing, deleting, yanking and pasting replace the active region) and `kill-ring-max` (120).
