(import (tuna) (test) (test-user) (buffers) (document) (views) (terminal) (terminal-test))

(define (edits b version)
  (map (lambda (e) (list (buffers:edit-start e) (buffers:piece-length (buffers:edit-removed e))
                         (document:text (buffers:piece-document (buffers:edit-inserted e)))))
       (buffers:edits-since b version)))

(define (line-ids)
  (test-user:settle)
  (map (lambda (e) (test-user:element-attribute e "id")) (test-user:elements (test-user:screen) "line")))

(define (text-lines t) (terminal-test:lines (terminal-test:text t)))

(test "a row the program changes is written in place, from its start to its newline, and the rows it leaves alone keep their items"
  (let ([t (terminal:start '("sh" "-c" "stty -echo; printf '\\033[?1049h\\033[H'; seq 1 5; read x; printf '\\033[2;1Hbee\\033[4;1Hdee'; read x"))])
    (terminal-test:show! t)
    (terminal-test:wait-for t "5\n")
    (let ([ids (line-ids)] [version (buffers:version t)])
      (check (pair? ids))
      (terminal:send! t "\r")
      (terminal-test:wait-for t "dee")
      (check-equal? '((10 1 "dee") (6 1 "bee")) (edits t version))
      (check-equal? '("1" "bee" "3" "dee" "5") (terminal-test:screen-lines t))
      (check-equal? ids (line-ids)))
    (buffers:kill! t)))

(test "rows that scroll off the top move into the scrollback: the boundary moves past them, and the screen gains rows at its end"
  (let ([t (terminal:start '("sh" "-c" "stty -echo; seq 1 23; read x; printf '24\\n25\\n26\\n27\\n'; read x"))])
    (terminal-test:show! t)
    (terminal-test:wait-for t "23\n")
    ;; The scrollback is empty, so row 2's text starts at position 6,
    ;; past the openings of the document and its two nodes.
    (let ([two (buffers:anchor t 6)])
      (check-equal? "2" (document:text (buffers:document t) 6 7))
      (terminal:send! t "\r")
      (terminal-test:wait-for t "27\n")
      (check-equal? '("24" "25" "26" "27") (list-tail (terminal-test:screen-lines t) 19))
      (check-equal? '(4 #f) (list (buffers:anchor-position two) (buffers:anchor-deleted? two)))
      (check-equal? '("1" "2" "3" "4" "5" "6") (list-head (text-lines t) 6))
      (check-equal? '("5" "6") (list-head (terminal-test:screen-lines t) 2)))
    (buffers:kill! t)))

(test "a view at the cursor follows it, even when the output moves the cursor's row into the scrollback"
  (let ([t (terminal:start '("sh" "-c" "stty -echo; (echo; seq 25 60) > \"$HOME/out\"; seq 1 23; printf 24; read x; cat \"$HOME/out\"; read x"))])
    (terminal-test:show! t)
    (terminal-test:wait-for t "24")
    (let ([at-cursor? (lambda () (= (views:point (terminal-test:view)) (- (document:length (buffers:document t)) 3)))])
      (check (at-cursor?))
      (terminal:send! t "\r")
      (terminal-test:wait-for t "60\n")
      (test-user:settle)
      (check (at-cursor?))
      (check-equal? '("1" "2") (list-head (text-lines t) 2)))
    (buffers:kill! t)))

(test "a row the program wrapped goes on with the next one in the scrollback, whether that leaves the screen with it or later"
  (let ([t (terminal:start '("sh" "-c" "stty -echo; head -c 100 /dev/zero | tr '\\0' a; echo; seq 1 21; read x; echo x; read x; echo y; read x"))])
    (terminal-test:wait-for t "21\n")
    (terminal:send! t "\r")
    (terminal-test:wait-for t "x\n")
    (check-equal? '(80 20) (map string-length (list-head (text-lines t) 2)))
    (check-equal? '("21" "x") (list-tail (terminal-test:screen-lines t) 21))
    (terminal:send! t "\r")
    (terminal-test:wait-for t "y\n")
    (check-equal? '(100 1) (map string-length (list-head (text-lines t) 2)))
    (check-equal? '("x" "y") (list-tail (terminal-test:screen-lines t) 21))
    (buffers:kill! t)))
