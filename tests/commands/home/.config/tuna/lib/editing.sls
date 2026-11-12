#!tuna
;; Stands in for the editing plugin, which this configuration lacks.
(import (commands) (views) (buffers) (document))

(commands:define-command (forward-char [n (commands:prefix-number)])
  "Moves point forward N characters."
  (let ([view (views:current)])
    (views:set-point! view (+ (views:point view) n))))

;; In a text buffer of ASCII, a character's position is its offset plus
;; one, past the text node's opening token.
(define (forward-word-position buffer position n)
  (let* ([text (document:text (buffers:document buffer))] [size (string-length text)])
    (define (skip i word?)
      (if (and (< i size) (eq? (char-alphabetic? (string-ref text i)) word?))
          (skip (+ i 1) word?)
          i))
    (let loop ([i (- position 1)] [n n])
      (if (= n 0)
          (+ i 1)
          (loop (skip (skip i #f) #t) (- n 1))))))
