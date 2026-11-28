(import (tuna) (test) (test-runner) (test-user) (views) (layout) (minibuffer) (line-picker)
        (minibuffer-test reading) (completion-test picking) (minibuffer-test screen))

(define goto-line-in-view
  (case-lambda
    [(line) (goto-line-in-view line 0)]
    [(line column) (views:call-with-view (layout:selected-view) (lambda () (line-picker:goto-line line column)))]))

(test "M-g g reads a line number, offering the current line, so RET alone goes to that line's start; M-g M-g too"
  (test-user:show! "one\ntw|o\nthree\n")
  (test-user:press! "M-g g")
  (check-equal? "Go to line (default 2): " (minibuffer-test/screen:question))
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
  (check-equal? (list "" " [Please enter a number]") (list (minibuffer-test/reading:input) (minibuffer-test/screen:bracket)))
  (test-user:type! " 2 ")
  (test-user:press! "RET")
  (check-equal? (list "" " [Please enter a number]") (list (minibuffer-test/reading:input) (minibuffer-test/screen:bracket)))
  (test-user:type! "1")
  (test-user:press! "RET")
  (check-equal? "|one\ntwo\nthree\n" (test-user:text))
  (check-equal? '("1" " 2 " "x" "3") (list-head (line-picker:goto-line-history) 4)))

(test "M-n past the input inserts the default, the current line"
  (test-user:show! "one\ntw|o\nthree\n")
  (test-user:press! "M-g g M-n")
  (check-equal? "2" (minibuffer-test/reading:input))
  (check-equal? '("end of defaults") (minibuffer-test/screen:report-messages (lambda () (test-user:press! "M-n"))))
  (test-user:press! "M-p")
  (check-equal? "" (minibuffer-test/reading:input))
  (check-equal? '(cancelled) (completion-test/picking:quit!)))

(test "a number that is not whole is refused, as Emacs's forward-line refuses it"
  (test-user:show! "one\ntw|o\nthree\n")
  (test-user:press! "M-g g")
  (test-user:type! "2.5")
  (check-equal? '("not an exact integer") (minibuffer-test/screen:report-messages (lambda () (test-user:press! "RET"))))
  (check-raises assertion-violation? (goto-line-in-view 1.5))
  (check-raises assertion-violation? (goto-line-in-view 1 -1)))

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
  (check-equal? "Go to line (default 1): " (minibuffer-test/screen:question))
  (test-user:type! "3")
  (test-user:press! "RET")
  (check-equal? "one\ntwo\n|three\n" (test-user:text)))

(test "LINE:COLUMN goes to that column of the line, counting from 0; LINE: is the line's start, a column past the line's end is its end, and a column that is no number is refused"
  (test-user:show! "one\ntw|o\nthree\n")
  (for-each
    (lambda (typed text)
      (test-user:press! "M-g g")
      (test-user:type! typed)
      (test-user:press! "RET")
      (check-equal? text (test-user:text)))
    '("3:2" "1:" "2:9")
    '("one\ntwo\nth|ree\n" "|one\ntwo\nthree\n" "one\ntwo|\nthree\n"))
  (test-user:press! "M-g g")
  (test-user:type! "2:x")
  (test-user:press! "RET")
  (check-equal? (list "" " [Please enter a number]") (list (minibuffer-test/reading:input) (minibuffer-test/screen:bracket)))
  (check-equal? '(cancelled) (completion-test/picking:quit!))
  (check-equal? '("2:x" "2:9" "1:" "3:2") (list-head (line-picker:goto-line-history) 4)))
