(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (keys) (buffers) (document) (views) (layout) (layout-split)
        (editing) (files) (projects) (jump-history) (diagnostics) (diagnostics-list) (diagnostics-list-test lists))

(options:set! diagnostics:check-delay #f)

(keys:bind! keys:global "C-c l e" diagnostics-list:show-project-diagnostics)

(define (reports-during thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (test-runner:reports-during thunk)))

(define made '())

(hooks:add! diagnostics-list:mode-hook (lambda () (set! made (cons (buffers:current) made))))

(test-user:show! "|outside any project\n")

(test "a project's list raises in a buffer in no project"
  (check-equal? '((diagnostics-list:show-project-diagnostics "The buffer is in no project"))
                (reports-during (lambda () (test-user:press! "C-c l e")))))

(mkdir diagnostics-list-test/lists:root)
(mkdir (string-append diagnostics-list-test/lists:root "/.git"))

(define notes (files:visit (diagnostics-list-test/lists:write-file! "notes.txt" "alpha beta gamma\ndelta epsilon\nzeta eta\n")))

(layout:switch-to-buffer notes)

(diagnostics-list-test/lists:mode! notes #t)

(define source (diagnostics:make-source))

(diagnostics:report! source notes
  (list (diagnostics-list-test/lists:mark notes "beta" (diagnostics:severity warning) "vague")
        (diagnostics:make-diagnostic (diagnostics-list-test/lists:word notes "delta") (+ (diagnostics-list-test/lists:word notes "delta") 5) (diagnostics:severity error) "wrong"
          (diagnostics:details [origin "lint"] [code "E1"]))
        (diagnostics-list-test/lists:mark notes "zeta" (diagnostics:severity info) "short")))

(define other (diagnostics-list-test/lists:write-file! "other.txt" "one\ntwo\n"))

(diagnostics:report! source other (list (diagnostics:make-diagnostic '(2 . 1) '(2 . 3) (diagnostics:severity hint) "late")))

(define list-name (string-append diagnostics-list-test/lists:root "/"))

(define pv #f)

(test "a project's list holds the diagnostics of its buffers and of its files no buffer visits, ordered by file, each with its file from the root; making it runs the mode's hook in it"
  (test-user:press! "C-c l e")
  (set! pv (diagnostics-list-test/lists:list-view list-name))
  (check-equal? '(("notes.txt" "1:6" "warning" "vague") ("notes.txt" "2:0" "error" "lint E1" "wrong") ("notes.txt" "3:0" "info" "short")
                  ("other.txt" "2:1" "hint" "late"))
                (diagnostics-list-test/lists:rows pv))
  (check-equal? (list (views:buffer pv)) made)
  (check-equal? '("notes.txt" "wrong") (map test-user:element-text (diagnostics-list-test/lists:links pv 1))))

(test "RET on a row of a file no buffer visits visits it and goes there, highlighting the diagnostic"
  (layout:select! pv)
  (test-user:press! "M-> RET")
  (check-equal? (list "other.txt" 6 #t)
                (list (buffers:name (views:buffer (layout:selected-view))) (views:point (layout:selected-view)) (diagnostics-list-test/lists:pulsed? (layout:selected-view)))))

(test "a killed buffer's diagnostics leave the project's list"
  (buffers:kill! (files:buffer-visiting other))
  (check-equal? '("notes.txt" "notes.txt" "notes.txt") (map car (diagnostics-list-test/lists:rows pv))))

(test "a cleared file's diagnostics leave it"
  (let ([third (diagnostics-list-test/lists:write-file! "third.txt" "a\n")])
    (diagnostics:report! source third (list (diagnostics:make-diagnostic '(1 . 0) '(1 . 1) (diagnostics:severity hint) "x")))
    (check-equal? '("notes.txt" "notes.txt" "notes.txt" "third.txt") (map car (diagnostics-list-test/lists:rows pv)))
    (diagnostics:clear! source third)
    (check-equal? '("notes.txt" "notes.txt" "notes.txt") (map car (diagnostics-list-test/lists:rows pv)))))

(test "a click on a project list's file name selects the list and the row, then goes there, visiting a file no buffer visits"
  (let ([third (diagnostics-list-test/lists:write-file! "third.txt" "a\nb\nc\n")])
    (diagnostics:report! source third (list (diagnostics:make-diagnostic '(3 . 0) '(3 . 1) (diagnostics:severity hint) "last")))
    (layout:select! (car (views:showing notes)))
    (test-user:settle)
    (test-user:click-element! (car (diagnostics-list-test/lists:links pv 3)))
    (check-equal? (list "third.txt" 5 3 #t)
                  (list (buffers:name (views:buffer (layout:selected-view))) (views:point (layout:selected-view)) (diagnostics-list-test/lists:selected pv)
                        (diagnostics-list-test/lists:pulsed? (layout:selected-view))))))
