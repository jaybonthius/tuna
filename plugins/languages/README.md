# languages

What Tuna knows about each language: the major mode that edits it, the names and `#!` programs of its files, its tree-sitter grammar, how it writes comments, strings and brackets, and its word and symbol characters. A language plugin declares them once with `languages:define-language`; the plugins that choose modes, lex, highlight and start language servers read them.
