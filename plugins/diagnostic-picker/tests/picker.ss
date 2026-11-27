(import (tuna) (test) (test-user) (test-runner) (options) (buffers) (document) (views) (layout) (layout-split) (editing)
        (minibuffer) (completion) (completion-list) (files) (projects) (jump-history) (diagnostics) (diagnostic-picker)
        (jump-history-test))

(define here jump-history-test:here)

(define (home-path name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text) (call-with-output-file (home-path name) (lambda (p) (put-string p text)) 'replace))

(for-each mkdir (map home-path '("code" "code/.git" "code/sub" "plain")))
(write-file! "code/a.txt" "one\ntwo\nthree\nfour\nfive\n")
(write-file! "code/uses.txt" "x = total\ny = average + total\n")
(write-file! "code/sub/twice.txt" "note\ndef total\n")
(write-file! "plain/p.txt" "p\n")

(define notes (files:visit (home-path "code/a.txt")))
(define uses (files:visit (home-path "code/uses.txt")))

(define source (diagnostics:make-source))

(define (on-line n severity message) (diagnostics:make-diagnostic (cons n 0) #f severity message))

(for-each (lambda (b) (buffers:with-buffer b (options:set-local! diagnostics:mode #t))) (list notes uses))

(diagnostics:report! source notes
  (list (on-line 2 (diagnostics:severity warning) "two is vague") (on-line 4 (diagnostics:severity error) "four is wrong")
        (on-line 5 (diagnostics:severity info) "five is fine")))

(layout:switch-to-buffer notes)

(define (texts) (map cadr (jump-history-test:choices)))

(test "M-g f reads the buffer's diagnostics grouped by severity, most severe first, as NAME:LINE: TEXT; e SPC narrows to errors; RET goes there and M-, returns"
  (jump-history-test:line! 1)
  (test-user:press! "M-g f")
  (check-equal? '(("Errors" "a.txt:4: four is wrong") ("Warnings" "a.txt:2: two is vague") ("Infos" "a.txt:5: five is fine"))
                (jump-history-test:choices))
  (check (for-all (lambda (c) (eq? c completion:location-category)) (completion:session-categories (jump-history-test:session))))
  (test-user:type! "e ")
  (check-equal? '("a.txt:4: four is wrong") (texts))
  (test-user:press! "RET")
  (check-equal? '("a.txt" 4) (here))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 1) (here)))

(test "C-u M-g f reads the project's diagnostics, from files no buffer visits too, each group sorted by file and place"
  (layout:switch-to-buffer uses)
  (diagnostics:report! source uses (list (diagnostics:make-diagnostic '(2 . 4) #f (diagnostics:severity warning) "average is slow")))
  (diagnostics:report! source (home-path "code/sub/twice.txt")
    (list (diagnostics:make-diagnostic '(2 . 4) #f (diagnostics:severity error) "total twice")))
  (test-user:press! "C-u M-g f")
  (check-equal? '("a.txt:4: four is wrong" "twice.txt:2: total twice" "a.txt:2: two is vague" "uses.txt:2: average is slow" "a.txt:5: five is fine")
                (texts))
  (test-user:type! "twice")
  (check-equal? '("twice.txt:2: total twice") (texts))
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "twice.txt" (car (here)))))
  (check-equal? '("twice.txt" 2) (here))
  (test-user:press! "M-,")
  (check-equal? '("uses.txt" 1) (here)))

(test "a diagnostic of a buffer another view shows goes there and selects that view, recording the place it leaves"
  (layout:switch-to-buffer (buffers:find "twice.txt"))
  (let* ([v (jump-history-test:view)] [other (layout-split:display-below uses)])
    (layout:select! v)
    (test-user:press! "C-u M-g f")
    (test-user:type! "average")
    (check-equal? '("uses.txt:2: average is slow") (texts))
    (test-user:press! "RET")
    (check-equal? (list #t '("uses.txt" 2) "twice.txt" '("uses.txt" 1))
                  (list (eq? (jump-history-test:view) other) (here) (buffers:name (views:buffer v))
                        (car (jump-history-test:places))))
    (layout:select! v)
    (test-user:press! "C-x 1")
    (layout:switch-to-buffer notes)))

(test "M-g f marks the diagnostic's own range"
  (let ([four (document:line-start (buffers:document notes) 4)])
    (diagnostics:report! source notes (list (diagnostics:make-diagnostic (+ four 1) (+ four 3) (diagnostics:severity error) "ou")))
    (test-user:press! "M-g f")
    (jump-history-test:choices)
    (test-user:press! "RET")
    (check-equal? '("ou") (jump-history-test:pulsed (jump-history-test:view)))))

(test "a buffer that visits no file previews nothing and its read is in no category"
  (let ([scratch (buffers:make "scratch" "a\nb\n")])
    (layout:switch-to-buffer scratch)
    (buffers:with-buffer scratch (options:set-local! diagnostics:mode #t))
    (diagnostics:report! source scratch (list (on-line 2 (diagnostics:severity hint) "b here")))
    (test-user:press! "M-g f")
    (check-equal? '(("Hints" "scratch:2: b here")) (jump-history-test:choices))
    (check-equal? '(#f) (completion:session-categories (jump-history-test:session)))
    (test-user:press! "RET")
    (check-equal? '("scratch" 2) (here))))

(test "with no diagnostics it raises No diagnostics, and C-u outside a project The buffer is in no project"
  (diagnostics:clear! source)
  (layout:switch-to-buffer notes)
  (check-equal? '((diagnostic-picker:diagnostic "No diagnostics")) (jump-history-test:press-reporting! "M-g f"))
  (layout:switch-to-buffer (files:visit (home-path "plain/p.txt")))
  (check-equal? '((diagnostic-picker:diagnostic "The buffer is in no project")) (jump-history-test:press-reporting! "C-u M-g f")))
