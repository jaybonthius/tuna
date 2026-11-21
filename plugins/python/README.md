# python

The major mode for Python. It declares the language, `"python"`, so language servers serve its buffers, and chooses the mode for Python's files. Its tree-sitter highlights query, in `queries/python/`, extends nvim-treesitter's so that Python looks as in Emacs's `python-ts-mode`; `treesit` reads it because this plugin declares the language.
