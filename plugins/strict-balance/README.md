# strict-balance

A minor mode, off by default, with one rule: no command that types, deletes or kills a bracket or string quote leaves one without its partner, as paredit keeps Lisp code. It remaps `editing`'s typing, deleting and killing commands, so every key bound to them follows the rule, and asks the buffer's lexer through `syntax` what each character is, so it knows no language. `C-u` before a deleting or killing key does it unchecked.
