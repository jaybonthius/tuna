#!tuna
(import (spell words))
(define-option language "en" string? "The dictionary's language.")
(define-hook after-check)
(define (check w) (after-check w) (string-append (spell/words:lookup w) " in " (language)))
(define-syntax with-word (syntax-rules () [(_ w e) (let ([w "word"]) e)]))
(display "[spell body]\n")
