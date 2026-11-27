(import (tuna) (test) (test-user) (test-runner) (hooks) (buffers) (views) (layout) (files) (diagnostics)
        (completion-list) (xref) (xref-picker) (completion-test picking) (xref-test words))

(define (view) (layout:selected-view))

(define twice (xref-test/words:path "sub/twice.txt"))

(define (temporary-states)
  (map (lambda (name) (let ([b (buffers:find name)]) (and b (files:temporary? b)))) '("defs.txt" "twice.txt")))

(define (open?) (map (lambda (name) (and (buffers:find name) #t)) '("defs.txt" "twice.txt")))

(define (quit!) (check-equal? '(cancelled) (completion-test/picking:quit!)))

(define visits '())

(hooks:add! files:after-visit (lambda (b) (set! visits (cons (buffers:name b) visits))))

(define uses (files:visit (xref-test/words:path "uses.txt")))

(define (at-total!)
  (layout:switch-to-buffer uses)
  (views:set-point! (view) 6)
  (set! visits '()))

(define (preview-second!)
  (test-user:press! "M-.")
  (completion-test/picking:choices)
  (test-user:press! "C-n")
  (test-runner:wait-until (lambda () (buffers:find "twice.txt"))))

(test "a preview visits a file temporarily, running no files:after-visit entry, and a quit kills what it visited"
  (at-total!)
  (preview-second!)
  (check-equal? (list '() '(#t #t)) (list visits (temporary-states)))
  (quit!)
  (check-equal? (list '() '(#f #f)) (list visits (open?))))

(test "choosing a previewed file completes its visit and keeps it; the other previewed file goes"
  (at-total!)
  (preview-second!)
  (completion-test/picking:press-until-ended! "RET" xref:find-definitions)
  (check-equal? (list '("twice.txt") #f '(#f #t)) (list visits (files:temporary? (buffers:find "twice.txt")) (open?)))
  (test-user:press! "M-,")
  (buffers:kill! (buffers:find "twice.txt")))

(define source (diagnostics:make-source))

(define (twice-listed)
  (filter (lambda (m) (string=? m "total twice"))
          (map diagnostics:diagnostic-message (diagnostics:under (xref-test/words:path "")))))

(test "a report to a previewed file's path stays the file's, since a temporary buffer is no buffer visiting it, so a quit loses nothing"
  (at-total!)
  (preview-second!)
  (check-equal? '(#t #f) (list (files:temporary? (buffers:find "twice.txt")) (files:buffer-visiting twice)))
  (diagnostics:report! source twice (list (diagnostics:make-diagnostic '(2 . 4) #f (diagnostics:severity error) "total twice")))
  (check-equal? '("total twice") (twice-listed))
  (quit!)
  (check-equal? (list #f '("total twice")) (list (buffers:find "twice.txt") (twice-listed))))

(test "a file the user visits while its preview shows is visited for real, and the read's end keeps it"
  (at-total!)
  (preview-second!)
  (let ([opened (spawn-task (lambda (restore) (files:visit twice)))])
    (test-runner:wait-until (lambda () (eq? 'done (task-state opened)))))
  (check-equal? (list #f #t) (list (files:temporary? (buffers:find "twice.txt")) (eq? (files:buffer-visiting twice) (buffers:find "twice.txt"))))
  (quit!)
  (check-equal? (list #t '("total twice")) (list (and (buffers:find "twice.txt") #t) (twice-listed))))
