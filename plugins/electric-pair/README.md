# electric-pair

A minor mode, off by default, that inserts the closing bracket or quote when the opening one is typed, types over a closing one, deletes an empty pair together, and gives a closing bracket its own line when a line break is typed between a pair, as Emacs's `electric-pair-mode` does. What counts as a bracket or a string comes from the buffer's lexer through `syntax`.
