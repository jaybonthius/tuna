(import (tuna) (test) (test-runner) (test-user) (options) (keys) (buffers) (document) (views) (layout) (layout-split)
        (editing) (files) (jump-history) (diagnostics) (diagnostics-list) (diagnostics-list-test lists))

(options:set! diagnostics:check-delay #f)

(keys:bind! keys:global "C-c l b" diagnostics-list:show-buffer-diagnostics)

(define (places) (map (lambda (p) (cons (buffers:name (car p)) (cdr p))) (jump-history:places)))

(mkdir diagnostics-list-test/lists:root)
(mkdir (string-append diagnostics-list-test/lists:root "/.git"))

(define notes (files:visit (diagnostics-list-test/lists:write-file! "notes.txt" "alpha beta gamma\ndelta epsilon\nzeta eta\n")))

(layout:switch-to-buffer notes)

(define nv (layout:selected-view))

(diagnostics-list-test/lists:mode! notes #t)

(test-user:press! "C-c l b")

(define lv (diagnostics-list-test/lists:list-view "notes.txt"))

(define (list-end) (- (document:length (buffers:document (views:buffer lv))) 1))

(test "a click in an empty list selects its view, as a click anywhere does"
  (check-equal? '(() #t) (list (diagnostics-list-test/lists:rows lv) (eq? (layout:selected-view) nv)))
  (test-user:click! lv (list-end))
  (check (eq? (layout:selected-view) lv)))

(define source (diagnostics:make-source))

(diagnostics:report! source notes
  (list (diagnostics-list-test/lists:mark notes "beta" (diagnostics:severity warning) "vague")
        (diagnostics-list-test/lists:mark notes "delta" (diagnostics:severity error) "wrong")
        (diagnostics-list-test/lists:mark notes "zeta" (diagnostics:severity info) "short")))

(define (row-label i n) (list-ref (test-user:elements (list-ref (diagnostics-list-test/lists:row-elements lv) i) "ui-label") n))

(test "only a row's message is drawn as a link"
  (test-user:settle)
  (check-equal? '(("vague") ("wrong") ("short"))
                (map (lambda (i) (map test-user:element-text (diagnostics-list-test/lists:links lv i))) '(0 1 2))))

(test "a click on a row's line or severity selects the list and that row, and shows nothing elsewhere"
  (layout:select! nv)
  (views:set-point! nv 1)
  (test-user:settle)
  (test-user:click-element! (row-label 1 0))
  (check-equal? '(#t 1 1 #f) (list (eq? (layout:selected-view) lv) (diagnostics-list-test/lists:selected lv) (views:point nv) (diagnostics-list-test/lists:pulsed? nv))))

(test "a click on a message selects the list, then goes to the row's diagnostic in the view showing the source, which it selects; the list stays, the place left is recorded, and the diagnostic is highlighted"
  (layout:select! nv)
  (views:set-point! nv 1)
  (test-user:settle)
  (test-user:click-element! (car (diagnostics-list-test/lists:links lv 2)))
  (check-equal? (list #t (diagnostics-list-test/lists:word notes "zeta") #t '(("notes.txt" . 1)) #t)
                (list (eq? (layout:selected-view) nv) (views:point nv) (and (memq lv (layout:views)) #t) (places) (diagnostics-list-test/lists:pulsed? nv))))

(test "the middle button goes from a message too, and elsewhere in a row only selects the list and the row"
  (layout:select! nv)
  (test-user:settle)
  (test-user:click-element! (car (diagnostics-list-test/lists:links lv 0)) "<mouse-2>")
  (check-equal? (list #t (diagnostics-list-test/lists:word notes "beta")) (list (eq? (layout:selected-view) nv) (views:point nv)))
  (test-user:settle)
  (test-user:click-element! (row-label 1 0) "<mouse-2>")
  (check-equal? (list #t 1 (diagnostics-list-test/lists:word notes "beta")) (list (eq? (layout:selected-view) lv) (diagnostics-list-test/lists:selected lv) (views:point nv))))
