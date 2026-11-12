(import (tuna) (tuna plugins) (tuna eval))
(use-plugin spell
  (config
    (display "[spell config]\n")
    (set-option! spell:language "en-GB")
    (define (shout w) (string-upcase w))
    (add-hook! spell:after-check (lambda (w) (display (list 'hook (shout w))) (newline)))
    (display (list 'internal (spell/words:lookup "a") 'macro (spell:with-word w w)))
    (newline)))
(display (list 'after (spell:check "b") (shout "x")))
(newline)
(import (console))
