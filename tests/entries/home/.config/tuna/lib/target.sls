#!tuna
(import (hooks) (tables))
(hooks:define-hook greeted)
(tables:define-table names)
(define (text name) name)
(tables:set! names 'harpo "Harpo")
