(import (tuna) (test) (options) (buffers) (document) (syntax) (indentation) (comment-syntax) (chez-scheme)
        (chez-scheme-test scheme-buffers))

(define scheme-buffer chez-scheme-test/scheme-buffers:scheme-buffer)

(test "a Scheme buffer writes comments with ;, doubled alone on a line, at column 40 after code"
  (let ([b (scheme-buffer "c.ss" "(a)")])
    (buffers:with-buffer b
      (check-equal? '(1 40) (list (comment-syntax:add) (comment-syntax:column))))
    (check-equal? '(";" "") (call-with-values (lambda () (comment-syntax:delimiters b)) list))))

(test "Scheme's brackets are () and []; { is part of a symbol"
  (check-equal? '((#\( . #\)) (#\[ . #\])) (syntax:mode-bracket-pairs chez-scheme:mode)))

(test "TAB puts a line of one semicolon at the buffer's comment column"
  (let ([b (scheme-buffer "col.ss" "(f\n; note\n x)")])
    (buffers:with-buffer b (options:set-local! comment-syntax:column 12))
    (indentation:line! b 5)
    (check-equal? "(f\n            ; note\n x)" (chez-scheme-test/scheme-buffers:text b))))
