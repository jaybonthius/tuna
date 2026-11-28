(import (tuna) (test) (options) (buffers) (comment-syntax))

(test "with no mode setting them, a buffer has no comment syntax and the comment column is 32"
  (let ([b (buffers:make (buffers:free-name "plain") "text")])
    (buffers:with-buffer b
      (check-equal? '(#f "" 0 32)
                    (list (comment-syntax:start) (comment-syntax:end) (comment-syntax:add) (comment-syntax:column))))))

(test "the options refuse values of the wrong kind"
  (let ([refused? (lambda (c) (assertion-violation? c))])
    (check-raises refused? (options:set! comment-syntax:start ""))
    (check-raises refused? (options:set! comment-syntax:add -1))
    (check-raises refused? (options:set! comment-syntax:column 'right))))
