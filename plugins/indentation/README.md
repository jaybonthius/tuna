# indentation

How each line of a buffer is indented: a table from major mode to an indenter, a procedure that returns the column a line's text belongs at, and the procedures that write that indentation with spaces. Language plugins give their modes indenters here; `editing`'s `TAB` and `RET` use them.
