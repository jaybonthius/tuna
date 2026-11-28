# treesit-install

Installs the tree-sitter grammars `treesit` uses. When a buffer's language has a grammar built from source whose file is missing, it asks once a session, then fetches the grammar's pinned commit and compiles it in a run, `*treesit-install NAME*`, while typing goes on; the language's buffers are coloured when it ends. Needs git and a C compiler.
