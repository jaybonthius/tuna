(import (tuna) (test) (test-user) (layout) (views) (buffers) (document) (keys) (commands) (modes) (editing) (ui) (ui-test))

(define view ui-test:view)

(define (run-showcase) (views:with-view (view) (commands:run ui:showcase)))

(define (showcase) (buffers:find "*Showcase*"))

(define (node-where match?)
  (let ([doc (buffers:document (showcase))])
    (let loop ([p 0])
      (let ([t (document:token doc p)])
        (if (and (document:node? t) (match? t)) t (loop (+ p 1)))))))

(define (showcase-list rows)
  (node-where (lambda (t) (and (eq? (document:node-kind t) 'ui:list) (eq? (document:node-attribute t 'rows) rows)))))

(define (short) (showcase-list 'short))
(define (long) (showcase-list 'long))
(define (live kind) (node-where (lambda (t) (and (eq? (document:node-kind t) kind) (not (document:node-attribute t 'disabled))))))
(define (disabled kind) (node-where (lambda (t) (and (eq? (document:node-kind t) kind) (document:node-attribute t 'disabled)))))
(define (rows-of node) (- (document:node-end node) (document:node-start node) 2))

(define (described element)
  (list (ui-test:classes element) (test-user:element-attribute element "data-ui-state")
        (test-user:element-attribute element "aria-disabled") (test-user:element-text element)))

(test "ui:showcase shows *Showcase* in the current view, unmodified, with point on the first row of its first list"
  (run-showcase)
  (check-equal? "*Showcase*" (buffers:name (views:buffer (view))))
  (check-equal? '(0 #f) (list (ui:selected-row (short) (view)) (buffers:modified? (showcase)))))

(test "every component is drawn: a live button and link, each disabled, held hovered and pressed, labels and a row"
  (let ([drawn (ui-test:drawn (view))])
    (check-equal? '((("ui-button") #f #f "Push me") (("ui-button") "hover" #f "Push me") (("ui-button") "pressed" #f "Push me")
                    (("ui-button") #f "true" "Push me"))
      (map described (test-user:elements drawn "ui-button")))
    (let ([links (map described (test-user:elements drawn "ui-link"))])
      (check-equal? 3 (length links))
      (check (for-all (lambda (l) (member l links))
                      '((("ui-link") #f #f "Follow me") (("ui-link") "hover" #f "Follow me") (("ui-link") #f "true" "Follow me")))))
    (check (member '("ui-label" "ui-showcase-muted") (map ui-test:classes (test-user:elements drawn "ui-label"))))
    (check-equal? '("notes.org" "~/notes" "2 KB")
      (map test-user:element-text (test-user:elements (car (test-user:elements drawn "ui-row")) "ui-label")))))

(test "the first list holds eight rows under two headings, the second three hundred; the selected row is aria-current"
  (check-equal? '(8 300) (list (rows-of (short)) (rows-of (long))))
  (let ([drawn (ui-test:drawn (view))])
    (check-equal? "Notes" (test-user:element-text (car (test-user:elements drawn "ui-list-heading"))))
    (check-equal? "init.ssconfiguration"
      (test-user:element-text (find (lambda (e) (test-user:element-attribute e "aria-current")) (test-user:elements drawn "ui-list-row"))))))

(test "the buffer is read-only: in showcase-mode, derived from special, printing keys and g are undefined, and edits are refused"
  (check-equal? '("x is undefined" "g is undefined")
    (ui-test:report-messages (lambda () (test-user:press! "x") (test-user:press! "g"))))
  (check-raises (ui-test:raised? 'buffers:replace! "the text of *Showcase* is read-only") (buffers:replace! (showcase) 1 1 "x"))
  (check-equal? (list ui:showcase-mode #t) (list (modes:major-mode (showcase)) (modes:derived? ui:showcase-mode modes:special))))

(test "a click on the live button, or RET in it, counts in its label; the link counts the same way; the disabled ones count nothing"
  (ui-test:click-at! (view) (+ (document:node-start (live 'ui:%sample-button)) 2))
  (views:set-point! (view) (+ (document:node-start (live 'ui:%sample-button)) 2))
  (test-user:press! "RET")
  (ui-test:click-at! (view) (+ (document:node-start (live 'ui:%sample-link)) 2))
  (check-equal? '(2 1) (list (document:node-attribute (live 'ui:%sample-button) 'n) (document:node-attribute (live 'ui:%sample-link) 'n)))
  (check-equal? "Pushed 2 times" (test-user:element-text (car (ui-test:elements (view) "ui-button"))))
  (for-each
    (lambda (kind)
      (let ([at (+ (document:node-start (disabled kind)) 2)])
        (ui-test:click-at! (view) at)
        (views:set-point! (view) at)
        (test-user:press! "RET")))
    '(ui:%sample-button ui:%sample-link))
  (check-equal? '(0 0) (list (document:node-attribute (disabled 'ui:%sample-button) 'n) (document:node-attribute (disabled 'ui:%sample-link) 'n))))

(test "C-n moves through the rows, and RET chooses and shows the row chosen"
  (ui:select-row! (short) (view) 0)
  (test-user:press! "C-n C-n C-n C-n C-n C-n")
  (check-equal? 6 (ui:selected-row (short) (view)))
  (test-user:press! "RET")
  (check-equal? "Makefile" (document:node-attribute (live 'ui:%chosen) 'name)))

(test "a second view of the buffer selects its own row"
  (let ([other (views:make (showcase))])
    (ui:select-row! (long) other 250)
    (check-equal? '(6 250 #f) (list (ui:selected-row (short) (view)) (ui:selected-row (long) other) (ui:selected-row (long) (view))))))

(test "run from another buffer it starts again on the first row; run where it shows, it leaves point"
  (ui-test:show! (buffers:make "elsewhere" ""))
  (run-showcase)
  (check-equal? (list #t 0) (list (eq? (views:buffer (view)) (showcase)) (ui:selected-row (short) (view))))
  (test-user:press! "C-n")
  (run-showcase)
  (check-equal? 1 (ui:selected-row (short) (view))))

(test "reloading ui writes the lists' rows again from the same code; the counts live in the buffer and stay"
  (reload-modules! '((ui)))
  (check-equal? '(8 300 2) (list (rows-of (short)) (rows-of (long)) (document:node-attribute (live 'ui:%sample-button) 'n)))
  (check-equal? "notes.orgoutline"
    (test-user:element-text (find (lambda (e) (test-user:element-attribute e "aria-current")) (ui-test:elements (view) "ui-list-row")))))

(test "another buffer named *Showcase* is not the showcase: a reload leaves it alone, and the command refuses to take its name"
  (buffers:kill! (showcase))
  (let ([f (buffers:make "*Showcase*" (buffers:text '() "my notes\n"))])
    (reload-modules! '((ui)))
    (check-equal? "my notes\n" (ui-test:text f))
    (check-equal? '("a live buffer has the name") (ui-test:report-messages run-showcase))
    (buffers:kill! f)))

(test "q quits the showcase's view; RET on a row still chooses it"
  (run-showcase)
  (test-user:press! "C-n RET")
  (check-equal? '(1 "notes.org") (list (ui:selected-row (short) (view)) (document:node-attribute (live 'ui:%chosen) 'name)))
  (test-user:press! "q")
  (check (not (eq? (views:buffer (view)) (showcase)))))
