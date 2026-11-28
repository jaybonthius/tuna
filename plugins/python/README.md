# python

The major mode for Python. It declares Python with `languages`: its mode, file names, `#!` programs, grammar, comment, string and bracket syntax, and word and symbol characters, so language servers serve its buffers by the language `"python"`, and `syntax` lexes them. Its tree-sitter highlights query, in `queries/python/`, extends nvim-treesitter's so that Python looks as in Emacs's `python-ts-mode`; `treesit` reads it because this plugin gives Python its mode.

