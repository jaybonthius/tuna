#!tuna
(import (echo-area) (hooks))
(hooks:define-hook poke)
(define (say) (echo-area:message! "Poked"))
(hooks:add! poke say)
