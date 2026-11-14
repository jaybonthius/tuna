# undo-log

Keeps a log of each file buffer's undo history, written after every batch by the plugin's own thread, so the history survives restarts and unsaved edits come back when the file is visited again.
