(import (tuna) (tuna plugins))
(use-plugin ansi-colors)
(import (prefix (ghostty) ghostty:))

(define stretches '())

(define (note! text value) (set! stretches (cons (cons text value) stretches)))

(define filter (ansi-colors:filter note!))

;; Each read starts from the plain style, with a filter of its own.
(define (read! . texts)
  (let ([fresh (ansi-colors:filter note!)])
    (set! stretches '())
    (for-each fresh texts)
    (reverse stretches)))

(define palette (ghostty:color-default-palette))
(import (console))
