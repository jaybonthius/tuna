#!tuna
(import (options))
(options:define-option auto #f boolean?)
(options:define-option auto-delay 0.2 real?)
(options:define-option auto-prefix 3 fixnum?)
(define (mode) 'corfu)
