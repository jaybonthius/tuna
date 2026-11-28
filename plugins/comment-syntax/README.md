# comment-syntax

How a major mode writes comments: options that default to the comments the buffer's language declares, which a mode hook or a buffer sets locally, and `comment-syntax:delimiters`, which gives a buffer's start and end of a comment from them. The `comment` plugin's commands and a language's indenter read them.
