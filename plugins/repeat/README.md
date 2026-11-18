# repeat

Repeating keymaps: after a command run by two or more keys, a keymap in `keys:repeat-keymaps` that binds the last of them to that command stays, so `C-x } } }` runs the command three times; any other key ends it and runs as usual. Each repetition shows the keys that go on in the echo area, as `Repeat with }, {`, until the repetition ends.
