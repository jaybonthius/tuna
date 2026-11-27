(import (tuna) (terminal) (terminal-test))

(define t (terminal:start #f))
(terminal:start '("sleep" "30"))
(terminal-test:wait-for t "$ ")
(terminal:send! t "cd /tmp; seq 1 30\r")
(terminal-test:wait-for t "\n30\n$ ")
