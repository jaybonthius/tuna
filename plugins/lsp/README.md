# lsp

Connects buffers to language servers over the Language Server Protocol. A server is described by name; a buffer's language lists its servers; each runs once per root and serves every buffer of that root whose language lists it, and once more, with no root, for the files in no project. A buffer's servers start when a view first draws it.
