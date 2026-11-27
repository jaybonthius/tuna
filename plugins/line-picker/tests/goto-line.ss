(import (tuna) (test) (test-user) (views) (layout) (minibuffer) (line-picker)
        (completion-test picking))

(define (question)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-question")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(define (bracket)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-message")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(define (input) (minibuffer:input (minibuffer:current-prompt)))

(define (messages-during thunk)
  (map (lambda (c) (if (cancelled? c) 'cancelled (condition-message c))) (completion-test/picking:reports-during thunk)))

(define (goto-line-in-view line) (views:call-with-view (layout:selected-view) (lambda () (line-picker:goto-line line))))

(test "M-g g reads a line number, offering the current line, so RET alone goes to that line's start; M-g M-g too"
  (test-user:show! "one\ntw|o\nthree\n")
  (test-user:press! "M-g g")
  (check-equal? "Go to line (default 2): " (question))
  (test-user:press! "RET")
  (check-equal? "one\n|two\nthree\n" (test-user:text))
  (test-user:press! "M-g M-g")
  (test-user:type! "3")
  (test-user:press! "RET")
  (check-equal? "one\ntwo\n|three\n" (test-user:text)))

(test "the place point left is recorded, so M-, returns to it"
  (test-user:show! "one\ntw|o\nthree\n")
  (test-user:press! "M-g g")
  (test-user:type! "3")
  (test-user:press! "RET")
  (test-user:press! "M-,")
  (check-equal? "one\ntw|o\nthree\n" (test-user:text)))

(test "input that is no number, or a number with spaces around it, is refused with Please enter a number and asked again"
  (test-user:show! "one\ntwo\nth|ree\n")
  (test-user:press! "M-g g")
  (test-user:type! "x")
  (test-user:press! "RET")
  (check-equal? (list "" " [Please enter a number]") (list (input) (bracket)))
  (test-user:type! " 2 ")
  (test-user:press! "RET")
  (check-equal? (list "" " [Please enter a number]") (list (input) (bracket)))
  (test-user:type! "1")
  (test-user:press! "RET")
  (check-equal? "|one\ntwo\nthree\n" (test-user:text))
  (check-equal? '("1" " 2 " "x" "3") (list-head (line-picker:goto-line-history) 4)))

(test "M-n past the input inserts the default, the current line"
  (test-user:show! "one\ntw|o\nthree\n")
  (test-user:press! "M-g g M-n")
  (check-equal? "2" (input))
  (check-equal? '("end of defaults") (messages-during (lambda () (test-user:press! "M-n"))))
  (test-user:press! "M-p")
  (check-equal? "" (input))
  (check-equal? '(cancelled) (completion-test/picking:quit!)))

(test "a number that is not whole is refused, as Emacs's forward-line refuses it"
  (test-user:show! "one\ntw|o\nthree\n")
  (test-user:press! "M-g g")
  (test-user:type! "2.5")
  (check-equal? '("not an exact integer") (messages-during (lambda () (test-user:press! "RET"))))
  (check-raises assertion-violation? (goto-line-in-view 1.5)))

(test "a line past the last goes to the end, one before the first to the start, and with no final newline to the end of the last line"
  (test-user:show! "one\ntw|o\nthree\n")
  (goto-line-in-view 99)
  (check-equal? "one\ntwo\nthree\n|" (test-user:text))
  (goto-line-in-view -4)
  (check-equal? "|one\ntwo\nthree\n" (test-user:text))
  (test-user:show! "one\ntwo\nth|ree")
  (goto-line-in-view 4)
  (check-equal? "one\ntwo\nthree|" (test-user:text)))

(test "a numeric prefix argument is the line, read from no prompt; C-u alone is no number, so the line is read"
  (test-user:show! "one\ntwo\nth|ree\n")
  (test-user:press! "C-u 2 M-g g")
  (check-equal? (list "one\n|two\nthree\n" #f) (list (test-user:text) (minibuffer:current-prompt)))
  (test-user:press! "M-- M-g g")
  (check-equal? "|one\ntwo\nthree\n" (test-user:text))
  (test-user:press! "C-u M-g g")
  (check-equal? "Go to line (default 1): " (question))
  (test-user:type! "3")
  (test-user:press! "RET")
  (check-equal? "one\ntwo\n|three\n" (test-user:text)))
