# treesit

Colours buffers with tree-sitter. It names each language's grammar, a parser in a shared object, and gives `syntax-highlighting` one highlighter for those languages, whose job parses the buffer and matches the language's highlights queries: nvim-treesitter's, in `nvim-treesitter/`, those in the `queries/` folder of each plugin whose mode declares the language, and the user's. The plain library `(treesit highlight)` reads the queries and matches them.
