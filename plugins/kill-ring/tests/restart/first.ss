(import (buffers) (kill-ring))

(define b (buffers:make "b" "Hello world\n"))
(kill-ring:push! (list "first"))
(kill-ring:push! (list "x" (make-string 4097 #\z)))
(kill-ring:push! (list (buffers:piece b 1 6) "two"))
(kill-ring:append! (list " there" "!"))
(kill-ring:push! (list "newest"))
(kill-ring:rotate! 3)
