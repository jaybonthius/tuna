(library (wraps)
  (export wrapped-greeting)
  (import (chezscheme) (greeter))
  (define (wrapped-greeting) (greeter:greeting)))
