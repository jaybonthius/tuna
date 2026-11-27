(import (tuna) (test) (test-user) (test-runner) (options) (tables) (timers) (faces) (buffers) (document) (views) (layout) (files) (projects)
        (jump-history) (completion) (completion-list) (xref) (xref-picker) (completion-test sessions) (completion-test picking)
        (xref-test words))

(define (view) (layout:selected-view))

(define (here)
  (let ([b (views:buffer (view))])
    (list (buffers:name b) (document:line (buffers:document b) (views:point (view))))))

(define (places)
  (map (lambda (p) (list (buffers:name (car p)) (document:line (buffers:document (car p)) (cdr p)))) (jump-history:places)))

(define (session) (completion-test/picking:session))

(define (quit!) (check-equal? '(cancelled) (completion-test/picking:quit!)))

(define (open?) (map (lambda (name) (and (buffers:find name) #t)) '("defs.txt" "twice.txt")))

(define (rows)
  (completion-test/picking:choices)
  (let ([s (session)])
    (map (lambda (m) (list (completion:title s m) (completion:row-text s m))) (completion-test/sessions:matches s))))

(define (kill-others!)
  (for-each (lambda (name) (let ([b (buffers:find name)]) (when b (buffers:kill! b)))) '("defs.txt" "twice.txt")))

(define uses (files:visit (xref-test/words:path "uses.txt")))

(define (at-total!)
  (layout:switch-to-buffer uses)
  (views:set-point! (view) 6))

(define (start-shown start)
  (let ([b (views:buffer start)]) (list (buffers:name b) (document:line (buffers:document b) (views:point start)))))

(test "outside a project each candidate's group is its path as ~ writes it, and one item is gone to without asking"
  (at-total!)
  (test-user:press! "M-.")
  (check-equal? '(("~/code/defs.txt" "1: def total") ("~/code/sub/twice.txt" "2: def total")) (rows))
  (quit!)
  (kill-others!)
  (views:set-point! (view) 15)
  (completion-test/picking:press-until-ended! "M-." xref:find-definitions)
  (check-equal? (list '("defs.txt" 2) #f) (list (here) (session)))
  (test-user:press! "M-,")
  (kill-others!))

(options:set! projects:extra-root-markers '(".project"))
(call-with-output-file (xref-test/words:path ".project") (lambda (p) (put-string p "")) 'replace)

(test "several items are read grouped by file under the path from the project's root, each row the line and summary"
  (at-total!)
  (test-user:press! "M-.")
  (check-equal? '(("defs.txt" "1: def total") ("sub/twice.txt" "2: def total")) (rows))
  (quit!))

(test "the selected item's place is shown in the view the search started from; a quit puts it back, kills the buffers the preview opened and records nothing"
  (at-total!)
  (let ([start (view)])
    (test-user:press! "M-.")
    (rows)
    (test-runner:wait-until (lambda () (equal? (start-shown start) '("defs.txt" 1))))
    (test-user:press! "C-n")
    (test-runner:wait-until (lambda () (equal? (start-shown start) '("twice.txt" 2))))
    (check-equal? '(#t #t) (open?))
    (quit!)
    (check-equal? '(("uses.txt" 1) (#f #f) ()) (list (here) (open?) (places)))))

(test "choosing goes to the item, keeps the chosen file's buffer and records the place left, so M-, returns"
  (at-total!)
  (test-user:press! "M-.")
  (rows)
  (test-user:press! "C-n")
  (completion-test/picking:press-until-ended! "RET" xref:find-definitions)
  (check-equal? '(("twice.txt" 2) (#f #t) (("uses.txt" 1))) (list (here) (open?) (places)))
  (test-user:press! "M-,")
  (check-equal? '("uses.txt" 1) (here))
  (kill-others!))

(test "with xref-picker:preview-delay an item is shown once it has stayed selected that long"
  (options:set! xref-picker:preview-delay 0.3)
  (at-total!)
  (let ([start (view)])
    (test-user:press! "M-.")
    (rows)
    (check-equal? "uses.txt" (car (start-shown start)))
    (test-runner:wait-until (lambda () (equal? (car (start-shown start)) "defs.txt")))
    (quit!))
  (options:unset! xref-picker:preview-delay))

;; The backend's search pauses until the test lets it answer, so a newer
;; input lands while it still works.
(define asked '())
(define held? #f)

(define (hold apropos view pattern)
  (set! asked (cons pattern asked))
  (guard (c [(cancelled? c) (set! asked (cons (list 'quit pattern) asked)) (raise c)])
    (let wait () (when held? (timers:sleep 0.01) (wait))))
  (apropos view pattern))

(test "C-M-. asks the backend's apropos with the whole input once it is long enough and has rested, quits the ask a newer input replaces, and goes to the item chosen"
  (options:set! completion:async-min-input 2)
  (options:set! completion:async-delay 0.1)
  (advice-add! xref:apropos hold)
  (set! held? #t)
  (at-total!)
  (test-user:press! "C-M-.")
  (test-user:type! "t")
  ;; A short input asks nothing, so the test waits past the delay.
  (timers:sleep 0.3)
  (check-equal? '() asked)
  (test-user:type! "o")
  (test-runner:wait-until (lambda () (equal? asked '("to"))))
  (test-user:press! "DEL DEL")
  (test-user:type! "av")
  (test-runner:wait-until (lambda () (member "av" asked)))
  (check-equal? '("av" (quit "to") "to") asked)
  (set! held? #f)
  (test-runner:wait-until (lambda () (equal? (completion-test/sessions:texts (session)) '("def average"))))
  (let* ([s (session)] [m (car (completion-test/sessions:matches s))])
    (check-equal? (list (cons faces:shadow "~/code/defs.txt:2")) (completion:annotation s m)))
  (completion-test/picking:press-until-ended! "RET" xref-picker:find-apropos)
  (check-equal? (list '("defs.txt" 2) '("uses.txt" 1)) (list (here) (car (places))))
  (advice-remove! xref:apropos hold)
  (options:unset! completion:async-min-input)
  (options:unset! completion:async-delay))

(test "an identifier's annotation is its path and line, and its kind when it has one, in the shadow face"
  (let ([annotate ((tables:ref completion:annotators xref-picker:symbol-category #f) #f)] [defs (xref-test/words:path "defs.txt")])
    (check-equal? (list (cons faces:shadow "~/code/defs.txt:2") (cons faces:shadow "function"))
                  (annotate (xref:make-item "def average" defs 2 0 "function") #f))
    (check-equal? (list (cons faces:shadow "~/code/defs.txt:2")) (annotate (xref:make-item "def average" defs 2 0) #f))))
