#!tuna
(import (modes) (hooks) (tables) (buffers) (document) (indentation))

(tables:define-table keymap)

(hooks:define-hook mode-hook)

(modes:define-major-mode mode
  (keymap keymap)
  (hook mode-hook))

(define (indenter buffer position)
  (let* ([doc (buffers:document buffer)]
         [before (document:text doc 0 position)]
         [depth (fold-left (lambda (n c) (case c [(#\() (+ n 1)] [(#\)) (- n 1)] [else n])) 0 (string->list before))]
         [closing? (and (< position (- (document:length doc) 1)) (eqv? (document:token doc position) #\)))])
    (* 2 (max 0 (if closing? (- depth 1) depth)))))

(tables:set! indentation:indenters mode indenter)
