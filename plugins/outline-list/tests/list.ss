(import (tuna) (test) (test-runner) (test-user) (options) (tables) (keys) (modes) (buffers) (document) (views) (layout)
        (layout-split) (editing) (jump-history) (ui) (outline) (outline-list) (outline-test toy))

(options:set! outline:idle-delay 0.05)

(keys:bind! keys:global "C-c o s" outline-list:show)

(define cart-text "notes\nclass Cart\n  method total\n    body\n  method add\n    body\nfunction helper\n  body\n")

(define cart (buffers:make "cart.toy" cart-text))
(modes:set-major-mode outline-test/toy:mode cart)

(define (view) (layout:selected-view))

(define (cart-view) (find (lambda (v) (eq? (views:buffer v) cart)) (layout:views)))

(define (list-buffer) (buffers:find "*Outline cart.toy*"))

(define (list-view) (find (lambda (v) (eq? (views:buffer v) (list-buffer))) (layout:views)))

(define (place v)
  (let* ([doc (buffers:document (views:buffer v))] [p (views:point v)]) (list (document:line doc p) (document:column doc p))))

(define (selected-row)
  (let ([s (ui:section-at (list-view))]) (and s (ui:section-value s))))

(define (section . values)
  (ui:find-section (list-buffer) (map (lambda (v) (cons 'entry v)) values)))

(define (select-row! . values)
  (views:set-point! (list-view) (ui:section-heading-start (apply section values))))

(define (start!)
  (layout:switch-to-buffer cart)
  (views:set-point! (view) (editing:line-position cart 4 6))
  (test-user:press! "C-c o s")
  (test-runner:wait-until (lambda () (and (list-buffer) (eq? (view) (list-view))))))

(define (finish!)
  (layout:select! (cart-view))
  (layout:reset-layout))

(test "show lists the outline in another view, which it selects, one nested section for each entry, the row of the entry at point selected"
  (start!)
  (check-equal? "*Outline cart.toy*" (buffers:name (views:buffer (view))))
  (check-equal? "Cart/total" (selected-row))
  (check (section "Cart"))
  (check (section "Cart/add" "Cart"))
  (check (section "helper"))
  (check-equal? '(("Cart" "class" "type") ("total" "method" "function.method") ("add" "method" "function.method")
                  ("helper" "function" "function"))
                (map (lambda (e) (list (test-user:element-text e) (test-user:element-attribute e "data-kind")
                                       (test-user:element-attribute e "data-face")))
                     (test-user:elements-with (test-user:screen) "data-kind")))
  (finish!))

(test "RET goes to the selected row's entry name in the listed buffer's view, selects it and records the place, so M-, returns"
  (start!)
  (select-row! "Cart/add" "Cart")
  (test-user:press! "RET")
  (check (eq? (view) (cart-view)))
  (check-equal? '(5 9) (place (view)))
  (test-user:press! "M-,")
  (check-equal? '(4 6) (place (view)))
  (finish!))

(test "a click on a row goes to its entry"
  (start!)
  (test-user:click! (list-view) (+ 2 (ui:section-heading-start (section "helper"))))
  (check (eq? (view) (cart-view)))
  (check-equal? '(7 9) (place (view)))
  (finish!))

(test "SPC goes to the entry and leaves the list's view selected"
  (start!)
  (select-row! "helper")
  (test-user:press! "SPC")
  (check (eq? (view) (list-view)))
  (check-equal? '(7 9) (place (cart-view)))
  (finish!))

(test "n and p select the next and previous rows and show their entries, the list's view staying selected and nothing recorded"
  (start!)
  (let ([places (length (jump-history:places))])
    (test-user:press! "n")
    (check-equal? "Cart/add" (selected-row))
    (check-equal? '(5 9) (place (cart-view)))
    (test-user:press! "p")
    (check-equal? "Cart/total" (selected-row))
    (check-equal? '(3 9) (place (cart-view)))
    (check (eq? (view) (list-view)))
    (check-equal? places (length (jump-history:places))))
  (finish!))

(test "TAB on a parent folds its children and unfolds them; S-TAB cycles every section"
  (start!)
  (select-row! "Cart")
  (test-user:press! "TAB")
  (check (ui:section-hidden? (list-view) (section "Cart")))
  (test-user:press! "TAB")
  (check-equal? #f (ui:section-hidden? (list-view) (section "Cart")))
  (test-user:press! "S-TAB")
  (let ([after (ui:section-hidden? (list-view) (section "Cart"))])
    (test-user:press! "S-TAB")
    (check (not (eq? after (ui:section-hidden? (list-view) (section "Cart")))))
    (when (ui:section-hidden? (list-view) (section "Cart")) (test-user:press! "S-TAB")))
  (finish!))

(test "an edit of the listed buffer remakes the list once the outline is made again at idle, keeping folds and the selected entry"
  (start!)
  (select-row! "Cart")
  (test-user:press! "TAB")
  (select-row! "helper")
  (let ([add (editing:line-position cart 5 9)])
    (buffers:replace! cart add (+ add 3) "plus"))
  (test-user:press! "C-l")
  (test-runner:wait-until (lambda () (section "Cart/plus" "Cart")))
  (check-equal? #f (section "Cart/add" "Cart"))
  (check (ui:section-hidden? (list-view) (section "Cart")))
  (check-equal? "helper" (selected-row))
  (let ([plus (editing:line-position cart 5 9)])
    (buffers:replace! cart plus (+ plus 4) "add"))
  (test-user:press! "C-l")
  (test-runner:wait-until (lambda () (section "Cart/add" "Cart")))
  (select-row! "Cart")
  (test-user:press! "TAB")
  (finish!))

(test "after a remake that changes no name, as an edit inside a body gives, the list still follows its buffer's renames"
  (start!)
  (let ([body (editing:line-position cart 4 4)] [asked (outline-test/toy:asked cart)])
    (buffers:replace! cart body body "x")
    (test-user:press! "C-l")
    (test-runner:wait-until (lambda () (> (outline-test/toy:asked cart) asked))))
  (let ([add (editing:line-position cart 5 9)])
    (buffers:replace! cart add (+ add 3) "plus"))
  (test-user:press! "C-l")
  (test-runner:wait-until (lambda () (section "Cart/plus" "Cart")))
  (let ([plus (editing:line-position cart 5 9)] [body (editing:line-position cart 4 4)])
    (buffers:replace! cart plus (+ plus 4) "add")
    (buffers:replace! cart body (+ body 1) ""))
  (test-user:press! "C-l")
  (test-runner:wait-until (lambda () (section "Cart/add" "Cart")))
  (finish!))

(test "g forgets the outline and makes the list again at once"
  (options:set! outline:idle-delay 30)
  (start!)
  (let ([add (editing:line-position cart 5 9)])
    (buffers:replace! cart add (+ add 3) "plus"))
  (check-equal? #f (section "Cart/plus" "Cart"))
  (test-user:press! "g")
  (test-runner:wait-until (lambda () (section "Cart/plus" "Cart")))
  (let ([plus (editing:line-position cart 5 9)])
    (buffers:replace! cart plus (+ plus 4) "add"))
  (test-user:press! "g")
  (test-runner:wait-until (lambda () (section "Cart/add" "Cart")))
  (options:set! outline:idle-delay 0.05)
  (finish!))

(test "with outline-list:follow? the selected row follows point in the listed buffer after each command"
  (options:set! outline-list:follow? #t)
  (start!)
  (layout:select! (cart-view))
  (test-user:press! "C-n")
  (check-equal? "Cart/add" (selected-row))
  (test-user:press! "C-n C-n")
  (check-equal? "helper" (selected-row))
  (options:unset! outline-list:follow?)
  (finish!))

(test "M-RET goes to the entry and quits the list's view"
  (start!)
  (select-row! "helper")
  (test-user:press! "M-RET")
  (check-equal? #f (list-view))
  (check (eq? (view) (cart-view)))
  (check-equal? '(7 9) (place (view))))

(test "a buffer with no outline raises This buffer has no outline"
  (layout:switch-to-buffer (buffers:make "plain.txt" "text"))
  (check-equal? '("This buffer has no outline")
                (map (lambda (c) (and (message-condition? c) (condition-message c)))
                     (test-runner:reports-during (lambda () (test-user:press! "C-c o s"))))))
