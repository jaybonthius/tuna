# undo

Each buffer's history as a tree of states, which undo and redo move between. A file buffer's history is kept in a log of its own, written after every batch by the plugin's own thread, so it survives restarts and unsaved edits come back when the file is visited again.
