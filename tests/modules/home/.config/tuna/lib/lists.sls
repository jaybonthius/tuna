#!tuna
(import (rename (only (chezscheme) map) (map chez:map)))
(define (map f xs) (list 'mine))
(define (twice xs) (map car xs))
(define (both xs) (list (map car xs) (chez:map - xs)))
