(import (tuna) (test) (test-user) (buffers) (document) (views) (layout) (files) (projects) (minibuffer) (jump-history)
        (completion) (completion-list) (save-place) (xref) (xref-picker) (completion-test picking) (xref-test words)
        (save-place-test visits))

(define (view) (layout:selected-view))

(define (here)
  (let ([b (views:buffer (view))])
    (list (buffers:name b) (document:line (buffers:document b) (views:point (view))))))

(define uses (files:visit (xref-test/words:path "uses.txt")))

(test "a jump to a definition in a file whose place save-place kept lands on the definition"
  (save-place-test/visits:leave! "code/defs.txt" 25)
  (check-equal? (cons (xref-test/words:path "defs.txt") 25) (assoc (xref-test/words:path "defs.txt") (save-place:places)))
  (layout:switch-to-buffer uses)
  (views:set-point! (view) 15)
  (completion-test/picking:press-until-ended! "M-." xref:find-definitions)
  (check-equal? '("defs.txt" 2) (here)))
