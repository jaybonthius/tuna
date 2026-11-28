#!tuna
(import (options))

(options:define-option start #f (lambda (v) (or (not v) (and (string? v) (fx> (string-length v) 0))))
  "The text that starts a comment the commands write, such as \";\"; #f where the mode has no comment syntax.")

(options:define-option end "" string?
  "The text that ends such a comment; empty for a comment that the end of its line ends.")

(options:define-option add 0 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many more times a one-character comment-syntax:start is written at the start of a comment alone on its line.")

(options:define-option column 32 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "The column of a comment after the code on its line.")
