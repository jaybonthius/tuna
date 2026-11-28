# show-paren

A minor mode, on by default, that highlights the bracket beside each cursor of each view with the bracket matching it, and marks a bracket with no match. Brackets and matches come from the buffer's lexer through `syntax`, so brackets in strings and comments are not highlighted. Typing a closing bracket whose match is off screen tells the user which line it matches.
