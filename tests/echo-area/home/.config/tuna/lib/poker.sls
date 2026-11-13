#!tuna
(import (echo-area))
(define-hook poke)
(define (say) (echo-area:message! "Poked"))
(add-hook! poke say)
