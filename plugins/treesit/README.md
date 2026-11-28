# treesit

Colours buffers with tree-sitter. It highlights every language whose `languages` declaration names a grammar, a parser in a shared object, with one `syntax-highlighting` highlighter, whose job parses the buffer and matches the grammar's highlights queries: nvim-treesitter's, in `nvim-treesitter/`, those in the `queries/` folder of the plugin that gives the language its mode, and the user's. The plain library `(treesit highlight)` reads the queries and matches them.
