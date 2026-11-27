(library (jobs-test wraps)
  (export wrapped-greeting)
  (import (chezscheme) (jobs-test greeter))
  (define (wrapped-greeting) (jobs-test/greeter:greeting)))
