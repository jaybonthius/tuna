(import (tuna) (test) (test-user) (test-runner) (hooks) (views) (layout) (editing) (completion)
        (file-picker) (completion-test picking) (file-picker-test tree))

(define (word-start)
  (let* ([v (views:current)] [buffer (views:buffer v)] [p (views:point v)]
         [s (editing:forward-word-position buffer p -1)])
    (and (< s p) (= (editing:forward-word-position buffer s 1) p) s)))

(define (zeds)
  (let ([s (word-start)])
    (and s (completion:region s (views:point (views:current)) (list (completion:source (candidates (vector "zeta" "zero"))))))))

(hooks:add! completion:find-region file-picker:file-name-region -2)
(hooks:add! completion:find-region zeds -1)

;; A region that gives way ends its session once its job answers, so the
;; test waits for a session that has settled.
(define (completed text)
  (test-user:show! (string-append text "|"))
  (test-user:press! "C-M-i")
  (test-runner:wait-until
    (lambda ()
      (let ([s (completion-test/picking:session)])
        (and s (not (completion:session-busy? s))))))
  (completion-test/picking:choices))

(test "a file name at point completes from its folder, and narrows as it is typed"
  (check-equal? '("sub/" "a.txt") (completed "~/notes/"))
  (test-user:type! "s")
  (check-equal? '("sub/") (completion-test/picking:choices))
  (test-user:press! "TAB")
  (check-equal? "~/notes/sub/|" (test-user:text))
  (test-user:press! "C-g"))

(test "where the name's folder does not exist the region gives way to the next entry"
  (check-equal? '("zero" "zeta") (completed "~/nothere/ze"))
  (test-user:press! "C-g"))

(test "a ~/ after a folder starts the name again"
  (check-equal? '("sub/" "a.txt") (completed "/nowhere/~/notes/"))
  (test-user:press! "C-g"))

(test "text before point without a slash is no file name"
  (check-equal? '("zero" "zeta") (completed "ze"))
  (test-user:press! "C-g"))

(define (target-at text)
  (test-user:show! text)
  (let ([t (file-picker:file-name-target (layout:selected-view))])
    (and t (list (completion:target-value t) (completion:target-text t)))))

(test "a file name with a slash at point is a target: its whole path joined to the buffer's folder, shown as ~ writes it; a ~user name and a name without a slash are none"
  (let ([home (getenv "HOME")])
    (check-equal? (list (string-append home "/src/notes.txt") "~/src/notes.txt") (target-at "see src/no|tes.txt"))
    (check-equal? (list "/etc/hosts" "/etc/hosts") (target-at "/etc/ho|sts"))
    (check-equal? #f (target-at "~ada/no|tes"))
    (check-equal? #f (target-at "no|tes.txt"))
    (check-raises assertion-violation? (file-picker:file-name-target 'v))))
