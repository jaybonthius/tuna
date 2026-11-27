(import (tuna) (test) (test-user) (web) (views) (buffers) (layout) (hooks) (tables) (commands) (keys) (transient)
        (transient-test))

(define log '())

(commands:define-command (where)
  "Notes the view, buffer and prefix argument it runs with."
  (set! log (cons (list (views:id (views:current)) (buffers:name (buffers:current)) (commands:prefix-argument)) log)))

(commands:define-command (note [what 'none]) "Notes WHAT." (set! log (cons what log)))

(transient:define-menu m "A menu.")

(transient:define-menu inner "An inner menu." (title "Inner"))

(commands:define-command (show-m) "Shows m." (transient:show! m))

(commands:define-command (show-inner) "Shows the inner menu." (transient:show! inner))

(keys:bind! keys:global "C-c t" show-m)
(keys:bind! keys:global "C-c o" note)
(keys:bind! keys:global "SPC" note)
(keys:bind! keys:global "<mouse-1>" note)

(transient:add! m "Actions"
  (transient:command "w" "Where" where)
  (transient:staying-command "s" "Where, staying" where)
  (transient:staying-command "i" "Inner, above" show-inner)
  (transient:command "o" "Inner, alone" show-inner))

(transient:add! inner #f (transient:command "w" "Where" where))

(tables:define-table mode-keys "A mode's keys.")

(keys:bind! mode-keys "C-g" note)
(keys:bind! mode-keys "ESC" note)
(keys:bind! mode-keys "w" note)

(hooks:add! keys:find-keymaps (lambda (client posn) (if posn '() (list mode-keys))) 50)

(define m-drawn '(("Actions" ("w" "Where") ("s" "Where, staying") ("i" "Inner, above") ("o" "Inner, alone"))))

(define (report-messages thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (condition-message c) reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(test-user:show! "|one\ntwo\n")

(define user-view (layout:selected-view))

(define (in-user-view? entry) (and (pair? entry) (= (car entry) (views:id user-view))))

(test "while a menu is open, its keymap and transient:keymap come first, for every client, before a mode's keys"
  (let ([other (test-user:open-client)])
    (test-user:press! "C-c t")
    (for-each
      (lambda (client)
        (let ([active (keys:active-keymaps client)])
          (check-equal? (list m transient:keymap) (list-head active 2))
          (check (memq mode-keys active))))
      (list (test-user:client) other))
    (web:close-client! other)))

(test "an entry runs in the menu's view, whether its key is typed or clicked, and other clients' keys and clicks reach it"
  (let ([other (test-user:open-client)])
    (set! log '())
    (test-user:press! "s")
    (transient-test:click-entry! "s")
    (test-user:press! other "s")
    (transient-test:click-entry! other "s" 1)
    (check-equal? '(#t #t #t #t) (map in-user-view? log))
    (check-equal? m-drawn (transient-test:menu))
    (check-equal? m-drawn (transient-test:menu other))
    (web:close-client! other)))

(test "C-g and ESC close the top menu, over a keymap that binds them"
  (test-user:press! "C-g")
  (check-equal? #f (transient-test:menu))
  (test-user:press! "C-g")
  (check-equal? 'none (car log))
  (set! log '())
  (test-user:press! "C-c t ESC")
  (check-equal? '(#f ()) (list (transient-test:menu) log))
  (test-user:press! "ESC")
  (check-equal? '(none) log))

(test "a staying command that shows a menu shows it above, so C-g comes back; a command entry that shows one shows it alone"
  (test-user:press! "C-c t i")
  (check-equal? '("Inner" (("w" "Where"))) (transient-test:menu))
  (test-user:press! "C-g")
  (check-equal? m-drawn (transient-test:menu))
  (test-user:press! "o")
  (check-equal? '("Inner" (("w" "Where"))) (transient-test:menu))
  (test-user:press! "C-g")
  (check-equal? #f (transient-test:menu)))

(test "a key the menu does not bind closes it and runs as usual, named keys included; a printing character it does not bind warns, and the menu stays"
  (test-user:press! "C-c t")
  (check-equal? '("z is not in this menu") (report-messages (lambda () (test-user:press! "z"))))
  (check-equal? m-drawn (transient-test:menu))
  (set! log '())
  (test-user:press! "C-c o")
  (check-equal? '(#f (none)) (list (transient-test:menu) log))
  (test-user:press! "C-c t SPC")
  (check-equal? '(#f (none none)) (list (transient-test:menu) log)))

(test "a press or click of any button on the menu outside its entries does nothing, the middle button on an entry presses it, and a click in the user's view closes the menu"
  (test-user:press! "C-c t")
  (set! log '())
  (for-each (lambda (button) (transient-test:click! (test-user:client) (transient-test:popup-view) button '(("token" . 1)))) '(1 2 3))
  (check-equal? '(() #t) (list log (equal? m-drawn (transient-test:menu))))
  (transient-test:click-entry! (test-user:client) "s" 2)
  (check-equal? '(#t) (map in-user-view? log))
  (transient-test:click! (test-user:client) user-view 1 '(("at" . 1) ("count" . 0)))
  (check-equal? '(#f none) (list (transient-test:menu) (car log))))

(test "a command run by other code than a key leaves the menu open"
  (test-user:press! "C-c t")
  (commands:run note 'aside)
  (test-user:settle)
  (check-equal? '(aside #t) (list (car log) (equal? m-drawn (transient-test:menu)))))

(test "C-u, M- with a digit and M-- keep the menu, so the entry gets the prefix argument, typed or clicked; so do the commands in transient:staying-commands"
  (test-user:press! "C-u s")
  (test-user:press! "M-5 s")
  (test-user:press! "M-- s")
  (check-equal? '(- 5 (4)) (map caddr (list-head log 3)))
  (test-user:press! "C-u")
  (transient-test:click-entry! "s")
  (check-equal? '(4) (caddr (car log)))
  (tables:set! transient:staying-commands views:scroll-up)
  (test-user:press! "C-v")
  (check-equal? m-drawn (transient-test:menu))
  (test-user:press! "C-u w")
  (check-equal? (list (views:id user-view) "*test*" '(4)) (car log))
  (check-equal? #f (transient-test:menu)))

(test "a key bound in transient:keymap, or to keys:keyboard-quit, closes the top menu"
  (keys:bind! transient:keymap "q" transient:quit)
  (test-user:press! "C-c t q")
  (check-equal? #f (transient-test:menu))
  (keys:bind! keys:global "<f5>" keys:keyboard-quit)
  (test-user:press! "C-c t <f5>")
  (check-equal? #f (transient-test:menu)))

(tables:define-table plain-keys "Plain keys.")

(tables:define-table sub-keys "Sub keys.")

(keys:bind! plain-keys "C-c w" where)
(keys:bind! plain-keys "C-c s" sub-keys)
(keys:bind! sub-keys "w" where)

(commands:define-command (show-plain) "Shows the plain keys." (transient:show! plain-keys))

(test "a click on a keymap's binding runs it in the menu's view and closes the menus; a click on a binding to a keymap shows it above"
  (commands:run show-plain)
  (test-user:settle)
  (check-equal? '((("C-c w" "test-file/transient/keys:where") ("C-c s" "Sub keys."))) (transient-test:menu))
  (transient-test:click-entry! "C-c s")
  (check-equal? '((("w" "test-file/transient/keys:where"))) (transient-test:menu))
  (test-user:press! "C-g")
  (transient-test:click-entry! "C-c w")
  (check-equal? (list #f (list (views:id user-view) "*test*" #f)) (list (transient-test:menu) (car log))))

(test "press and quit are marked for no mode, and press with no menu open warns"
  (check-equal? '(() ()) (map (lambda (c) (tables:ref commands:command-modes c #f)) (list transient:press transient:quit)))
  (check-equal? '("no menu is open") (report-messages (lambda () (commands:run transient:press)))))
