(import (tuna) (test) (test-browser) (test-runner) (cdp page) (options) (keys) (modes) (buffers) (document) (views) (layout)
        (layout-split) (editing) (ui) (outline) (outline-list) (outline-test toy))

(options:set! outline:idle-delay 0.05)

(keys:bind! keys:global "C-c o s" outline-list:show)

(define cart (buffers:make "cart.toy" "notes\nclass Cart\n  method total\n    body\n  method add\n    body\nfunction helper\n  body\n"))
(modes:set-major-mode outline-test/toy:mode cart)

(define page (test-browser:open (page-options [width 1200] [height 900] [color-scheme (color-scheme light)])))

(define (cart-view) (find (lambda (v) (eq? (views:buffer v) cart)) (layout:views)))

(define (list-view) (find (lambda (v) (eq? (views:buffer v) (buffers:find "*Outline cart.toy*"))) (layout:views)))

(define (place v)
  (let* ([doc (buffers:document (views:buffer v))] [p (views:point v)]) (list (document:line doc p) (document:column doc p))))

(define (selected-row)
  (let ([s (ui:section-at (list-view))]) (and s (ui:section-value s))))

(define (in-list selector)
  (let ([selector (format "[data-view=\"~a\"] ~a" (views:id (list-view)) selector)])
    (test-browser:call (lambda () (page-query page selector)))))

(define (heading-holding text)
  (find (lambda (e) (equal? text (test-browser:call (lambda () (element-text e))))) (in-list ".ui-section-heading")))

(define (start!)
  (layout:switch-to-buffer cart)
  (views:set-point! (layout:selected-view) (editing:line-position cart 4 6))
  (test-browser:press! page "C-c o s")
  (test-runner:wait-until (lambda () (eq? (layout:selected-view) (list-view))))
  (test-browser:wait-for-applied page))

(define (finish!)
  (layout:select! (cart-view))
  (layout:reset-layout)
  (test-browser:wait-for-applied page))

(test "each entry's name is marked clickable, and shows the pointer"
  (start!)
  (let ([names (in-list "[data-kind][data-keymap~=\"clickable\"]")])
    (check-equal? '("Cart" "total" "add" "helper") (test-browser:call (lambda () (map element-text names))))
    (check-equal? '("pointer" "pointer" "pointer" "pointer")
                  (test-browser:call (lambda () (map (lambda (e) (element-style e "cursor")) names)))))
  (finish!))

(test "a click on an entry's name selects its row and goes to its entry"
  (start!)
  (test-browser:click! page (car (in-list "[data-kind=\"function\"]")))
  (check-equal? "helper" (selected-row))
  (check (eq? (layout:selected-view) (cart-view)))
  (check-equal? '(7 9) (place (cart-view)))
  (finish!))

(test "a click on a row past its name moves point there and goes nowhere"
  (start!)
  (test-browser:click! page (heading-holding "helper"))
  (check-equal? "helper" (selected-row))
  (check (eq? (layout:selected-view) (list-view)))
  (check-equal? '(4 6) (place (cart-view)))
  (finish!))
