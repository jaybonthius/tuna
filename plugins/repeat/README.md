# repeat

Repeating keymaps: after a command run by two or more keys, a keymap in `repeat:keymaps` that binds the last of them to that command stays, so `C-x } } }` runs the command three times; any other key ends it and runs as usual.
