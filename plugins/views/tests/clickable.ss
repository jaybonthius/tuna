(import (tuna) (test) (views) (buffers) (document) (hooks) (tables) (commands) (keys) (test-user)
        (views-test page) (views-test md))

(define (clicks view)
  (map (lambda (e) (string->symbol (test-user:element-attribute e "data-click")))
       (test-user:elements-with (views-test/page:element-for-no-client view) "data-click")))

(commands:define-command (act) "Does something." (void))

(tables:define-table keys-a)
(tables:define-table blocking)
(tables:define-table link-keys)
(tables:define-table tab-keys)
(tables:define-table blocked-keys)
(tables:define-table bar-keys)

(buffers:define-kind button-a (inline) (keymap keys-a))
(buffers:define-layer links (keymap link-keys))

(define v (views:make (buffers:make (buffers:free-name "doc")
                        (views-test/md:doc '() (views-test/md:para '() "x " (button-a '() "a") " y\n")))))

(test "a keymap that binds no left click marks nothing, nor does one binding only other buttons or a modified click"
  (check-equal? '() (clicks v))
  (keys:bind! keys-a "<mouse-2>" act)
  (keys:bind! keys-a "<mouse-3>" act)
  (keys:bind! keys-a "C-<mouse-1>" act)
  (check-equal? '() (clicks v)))

(test "a node's element is clickable when a click runs a command, a binding made between draws showing at the second"
  (keys:bind! keys-a "<mouse-1>" act)
  (check-equal? '(clickable) (clicks v)))

(test "a node's element is inert when a click runs nothing, by keys:ignore or keys:undefined"
  (keys:bind! keys-a "<mouse-1>" keys:ignore)
  (check-equal? '(inert) (clicks v))
  (keys:bind! keys-a "<mouse-1>" keys:undefined)
  (check-equal? '(inert) (clicks v)))

(test "a press alone that runs a command makes the element clickable, as a tab is"
  (keys:bind! keys-a "<down-mouse-1>" act)
  (check-equal? '(clickable) (clicks v)))

(test "a keymap the click finds first, as a disabled button's, decides it"
  (keys:bind! keys-a "<mouse-1>" act)
  (keys:bind! keys-a "<down-mouse-1>" keys:ignore)
  (keys:bind! blocking "<mouse-1>" keys:ignore)
  (keys:bind! blocking "<down-mouse-1>" keys:ignore)
  (let ([block-a (lambda (client posn)
                   (let ([n (and posn (views:posn-node posn))])
                     (if (and n (eq? (document:node-kind n) (buffers:kind-name (buffers:constructor-kind button-a))))
                         (list blocking)
                         '())))])
    (hooks:add! keys:find-keymaps block-a -10)
    (check-equal? '(inert) (clicks v))
    (hooks:remove! keys:find-keymaps block-a)
    (check-equal? '(clickable) (clicks v))))

(test "a layer's keymap marks the elements of its spans"
  (let* ([t (buffers:make (buffers:free-name "text") "one two three\n")] [tv (views:make t)])
    (keys:bind! link-keys "<mouse-1>" act)
    (buffers:add-span! (buffers:layer t links) 5 8 '((face . link)))
    (let ([marked (test-user:elements-with (views-test/page:element-for-no-client tv) "data-click")])
      (check-equal? '(("clickable" "link" "two"))
        (map (lambda (e) (list (test-user:element-attribute e "data-click") (test-user:element-attribute e "data-face")
                               (test-user:element-text e)))
             marked)))))

(define (state-of keymap)
  (let* ([m (views:keymap-mark keymap)] [n (string-length (number->string (read (open-input-string m))))])
    (substring m n (string-length m))))

(test "a marked keymap is looked up alone: its mark ends in its state, inert only when it binds both keys to nothing"
  (keys:bind! tab-keys "<down-mouse-1>" act)
  (keys:bind! tab-keys "<mouse-1>" keys:ignore)
  (keys:bind! blocked-keys "<mouse-1>" keys:ignore)
  (keys:bind! blocked-keys "<down-mouse-1>" keys:ignore)
  (keys:bind! bar-keys "<down-mouse-1>" keys:ignore)
  (keys:bind! bar-keys "<mouse-3>" act)
  (check-equal? '(" clickable" " inert" "") (map state-of (list tab-keys blocked-keys bar-keys))))

(test "a key a mark leaves unbound stays out of it even when the global keymap binds it to keys:ignore"
  (keys:bind! keys:global "<mouse-1>" keys:ignore)
  (check-equal? "" (state-of bar-keys)))
