# syntax

Answers questions about the lexical structure of a buffer's text from its major mode's lexer: whether a position is in a string or a comment, which brackets hold it, where the sexp before or after it and the top-level form around it start and end. Also holds each mode's word and symbol characters, whose rule is the plain library `(syntax characters)`, and defines the layer of brackets a language's highlighter finds.
