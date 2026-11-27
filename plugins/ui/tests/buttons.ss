(import (tuna) (test) (test-user) (web) (layout) (views) (buffers) (document) (keys) (commands) (editing) (ui) (ui-test))

(define view ui-test:view)

(define pushed '())

(commands:define-command (note [button (ui:pushed-button)])
  "Notes the button pushed."
  (set! pushed (cons (document:node-attribute button 'n) pushed)))

(ui:define-button go note)
(ui:define-link more note)
(buffers:define-kind em (inline))

(define (button-elements v)
  (map (lambda (e) (list (car (ui-test:classes e)) (test-user:element-attribute e "type") (test-user:element-attribute e "tabindex")
                         (test-user:element-attribute e "aria-disabled") (test-user:element-text e)))
       (append (ui-test:elements v "ui-button") (ui-test:elements v "ui-link"))))

(define b (buffers:make "*buttons*" (buffers:text '() "Run " (go '((n . 1)) "Go") " or " (more '((n . 2)) "more") "\n")))

(test "a button kind binds a click, the middle button and RET to its command, and a press or a drag to keys:ignore"
  (check-equal? (list (cons "<mouse-1>" note) (cons "<mouse-2>" note) (cons "RET" note) (cons "<down-mouse-1>" keys:ignore)
                      (cons "<drag-mouse-1>" keys:ignore) (cons "<drag-mouse-2>" keys:ignore))
    (keys:bindings go-keys)))

(test "a button draws as button.ui-button and a link as button.ui-link, of type button, out of the tab order"
  (ui-test:show! b)
  (check-equal? '(("ui-button" "button" "-1" #f "Go") ("ui-link" "button" "-1" #f "more")) (button-elements (view))))

(test "a click on a button or link runs its command and leaves point and the selected view"
  (views:set-point! (view) 3)
  (ui-test:click-at! (view) 7)
  (ui-test:click-token! (view) 13)
  (check-equal? '((2 1) 3) (list pushed (views:point (view)))))

(test "a click runs the command for the view clicked, which stays unselected"
  (let ([other (views:make b)] [selected (view)])
    (ui-test:click-at! other 15)
    (check-equal? '(2 2 1) pushed)
    (check (eq? selected (view)))))

(test "the middle button pushes a button, and a middle drag off one pushes nothing"
  (ui-test:mouse! (view) "down" '(("at" . 7) ("count" . 0)) '("button" . 2))
  (ui-test:mouse! (view) "click" '(("at" . 7) ("count" . 0)) '("button" . 2))
  (ui-test:mouse! (view) "down" '(("at" . 7) ("count" . 0)) '("button" . 2))
  (ui-test:mouse! (view) "drag" '(("at" . 2) ("count" . 0)) '("button" . 2))
  (check-equal? '(1 2 2 1) pushed))

(test "RET with point in a button pushes it; outside every button the command's parameter raises"
  (views:set-point! (view) 7)
  (test-user:press! "RET")
  (check-equal? '(1 1 2 2 1) pushed)
  (views:set-point! (view) 2)
  (check-raises (ui-test:raised? 'ui:pushed-button "no button is at the click or at point")
    (views:with-view (view) (ui:pushed-button))))

(test "the node a click names is the button's even when its label holds other nodes"
  (buffers:replace! b 1 1 (go '((n . 3)) (em '() "Bold")))
  (ui-test:click-at! (view) 4)
  (check-equal? 3 (car pushed)))

(test "a click on the label of a button whose module is gone finds no button"
  (let ([c (buffers:make "*gone*" "\n")])
    (load-module! '(ui-test gone))
    (buffers:replace! c 1 1 (list 'ui-test/gone:bye '() "Bye"))
    (ui-test:show! c)
    (ui-test:click-at! (view) 3)
    (check-equal? '(hi) (ui-test:said))
    (unload-owner! (module-owner '(ui-test gone)))
    (check-equal? #f (buffers:kind 'ui-test/gone:bye))
    (views:set-point! (view) 3)
    (check-raises (ui-test:raised? 'ui:pushed-button "no button is at the click or at point")
      (views:with-view (view) (ui:pushed-button)))))

(define d (buffers:make "*disabled*" (buffers:text '() "Off " (go '((n . 4) (disabled . #t)) "Go") " " (more '((n . 5) (disabled . yes)) "more") "\n")))

(test "a button or link whose disabled attribute is not #f draws aria-disabled and is inert, and a click or RET on it runs nothing"
  (ui-test:show! d)
  (check-equal? '(("ui-button" "button" "-1" "true" "Go") ("ui-link" "button" "-1" "true" "more")) (button-elements (view)))
  (let ([before pushed] [other (views:make d)])
    (views:set-point! (view) 2)
    (ui-test:click-at! (view) 7)
    (ui-test:click-token! (view) 10)
    (ui-test:click-at! other 12)
    (ui-test:mouse! (view) "down" '(("at" . 7) ("count" . 0)) '("button" . 2))
    (ui-test:mouse! (view) "click" '(("at" . 7) ("count" . 0)) '("button" . 2))
    (check-equal? (list #t 2) (list (eq? pushed before) (views:point (view))))
    (views:set-point! (view) 7)
    (test-user:press! "RET")
    (views:set-point! (view) 12)
    (test-user:press! "RET")
    (check-equal? (list #t keys:ignore) (list (eq? pushed before) (views:with-view (view) (keys:lookup (test-user:client) "RET"))))))

(test "ui:disabled-keys binds the keys a button kind binds to keys:ignore"
  (check-equal? '(("<mouse-1>" . keys:ignore) ("<mouse-2>" . keys:ignore) ("RET" . keys:ignore) ("<down-mouse-1>" . keys:ignore)
                  ("<drag-mouse-1>" . keys:ignore) ("<drag-mouse-2>" . keys:ignore))
    (map (lambda (b) (cons (car b) (commands:command-name (cdr b)))) (keys:bindings ui:disabled-keys))))

(test "the layout's part mode reads keys in its own view, so RET there still leaves it on a disabled button"
  (let ([before pushed])
    (views:set-point! (view) 7)
    (test-user:press! "C-x w w")
    (check (layout:part-mode?))
    (test-user:press! "RET")
    (check-equal? (list #f #t) (list (layout:part-mode?) (eq? pushed before)))))

(test "without the attribute, the same button pushes again"
  (buffers:splice! d 5 9 (document:from-datum (go '((n . 4)) "Go")))
  (views:set-point! (view) 7)
  (test-user:press! "RET")
  (check-equal? 4 (car pushed)))

(test "the forms and helpers check what they are given"
  (check-equal? "expected (ui:define-button id command)"
    (guard (c [(syntax-violation? c) (condition-message c)]) (load-module! '(ui-test button-number))))
  (check-raises (ui-test:raised? 'ui:define-link "not a command") (load-module! '(ui-test link-number)))
  (check-raises (ui-test:raised? 'ui:label "not a string") (ui:label 'x))
  (check-raises (ui-test:raised? 'ui:label "not a string") (ui:label "x" 'y))
  (check-raises (ui-test:raised? 'ui:row "not HTML") (ui:row "x")))

(test "labels and rows are HTML: a span.ui-label with the class given, and a div.ui-row of items"
  (let* ([c (test-user:client)]
         [sxml (begin (web:send-screen! c (ui:row (ui:label "Name") (ui:label "notes.org" "file")) "ui") (test-user:screen c))]
         [row (car (test-user:elements sxml "ui-row"))])
    (check-equal? '((("ui-label") "Name") (("ui-label" "file") "notes.org"))
      (map (lambda (e) (list (ui-test:classes e) (test-user:element-text e))) (test-user:elements row "ui-label")))))
