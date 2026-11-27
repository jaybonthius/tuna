#!tuna
(import (options))
(options:define-option want-minibuffer #t boolean?)
(define (minibuffer?) (want-minibuffer))
