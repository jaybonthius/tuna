(import (tuna) (test) (test-user) (web) (views) (buffers) (layout) (layout-split) (tables) (commands) (keys) (transient)
        (transient-test) (transient-test magit) (transient-test plain))

(define merge-menu-drawn
  '("Merge" ("Arguments" ("- f" "Fast-forward only" "--ff-only") ("- n" "No fast-forward" "--no-ff") ("- s" "Strategy" "--strategy="))
    ("Actions" ("m" "Merge"))))

(define (raised-by who message)
  (lambda (c) (and (who-condition? c) (eq? who (condition-who c)) (message-condition? c) (string=? message (condition-message c)))))

(test-user:show! "|one\ntwo\n")

(test "a menu is a table, with its documentation"
  (check (tables:table? transient-test/magit:merge-menu))
  (check-equal? "Git's merge menu." (tables:documentation transient-test/magit:merge-menu)))

(test "showing a menu draws it at once in the buffer *transient*, and leaves the selected view selected"
  (let ([user-view (layout:selected-view)])
    (test-user:press! "C-c m")
    (check-equal? merge-menu-drawn (transient-test:menu))
    (check (transient:buffer? (views:buffer (transient-test:popup-view))))
    (check-equal? #f (transient:buffer? (views:buffer user-view)))
    (check (eq? user-view (layout:selected-view)))))

(test "an entry is a button holding its key in the keyword face, its description as a label and its argument in the shadow face, pressed while it is in"
  (let ([entry (lambda (key)
                 (find (lambda (e) (equal? key (test-user:element-text (car (test-user:elements e "transient-key")))))
                       (test-user:elements (test-user:screen) "transient-entry")))])
    (let ([e (entry "- f")])
      (check-equal? '(button "false" "keyword" "shadow")
                    (list (car e) (test-user:element-attribute e "aria-pressed")
                          (test-user:element-attribute (car (test-user:elements e "transient-key")) "data-face")
                          (test-user:element-attribute (car (test-user:elements e "transient-argument")) "data-face")))
      (check (member "ui-button" (list (test-user:element-attribute e "class") "ui-button"))))
    (test-user:press! "- f")
    (let ([e (entry "- f")])
      (check-equal? '("true" #f) (list (test-user:element-attribute e "aria-pressed")
                                       (test-user:element-attribute (car (test-user:elements e "transient-argument")) "data-face"))))
    (check-equal? #f (test-user:element-attribute (entry "m") "aria-pressed"))))

(test "showing the top menu again does nothing, so one C-g closes it, and its view goes"
  (commands:run transient-test/magit:merge)
  (test-user:press! "C-g")
  (check-equal? '(#f #f) (list (transient-test:menu) (transient-test:popup-view))))

(define branch "main")

(transient:define-menu status "The status menu."
  (title (lambda () (string-append "On " branch ", in " (buffers:name (buffers:current))))))

(commands:define-command (show-status) "Shows the status menu." (transient:show! status))

(keys:bind! keys:global "C-c s" show-status)

(test "a title may be a procedure, run at each draw in the menu's view"
  (test-user:press! "C-c s")
  (check-equal? '("On main, in *test*") (transient-test:menu))
  (set! branch "next")
  (test-user:settle)
  (check-equal? '("On next, in *test*") (transient-test:menu))
  (test-user:press! "C-g"))

(define (load-failure name)
  (guard (c [(message-condition? c) (list (and (who-condition? c) (condition-who c)) (condition-message c))])
    (load-module! (list 'transient-test name))
    #f))

(test "the form checks its shape when it expands, and its values when it runs"
  (check-equal? '((transient:define-menu "expected (transient:define-menu id doc-string clause ...)")
                  (transient:define-menu "expected (transient:define-menu id doc-string clause ...)")
                  (transient:define-menu "an unknown or repeated clause")
                  (transient:define-menu "an unknown or repeated clause")
                  (transient:define-menu "expected (incompatible (argument-string ...) ...)")
                  (transient:define-menu "neither a string nor a procedure")
                  (transient:define-menu "not an option")
                  (transient:define-menu "not a list of lists of strings")
                  (transient:define-menu "neither a string nor a procedure")
                  (transient:define-menu "not an option"))
                (map load-failure '(bad-1 bad-2 bad-3 bad-4 bad-5 bad-6 bad-7 bad-8 bad-9 bad-10))))

(test "the procedures check what they are given"
  (check-raises (raised-by 'transient:show! "not a table") (transient:show! 'menu))
  (check-raises (raised-by 'transient:buffer? "not a buffer") (transient:buffer? "notes"))
  (check-raises (raised-by 'transient:arguments "not a table") (transient:arguments 'menu))
  (let ([result #f])
    (join-task (fork-task (lambda (restore)
                            (set! result (guard (c [(message-condition? c) (condition-message c)])
                                           (transient:show! transient-test/magit:merge-menu))))))
    (check-equal? "not on the main thread" result)))

(test "when the module that defined a menu unloads, its menu closes"
  (load-module! '(transient-test extra))
  (test-user:press! "C-c m")
  (unload-owner! (module-owner '(transient-test extra)))
  (test-user:press! "C-g")
  (load-module! '(transient-test computed))
  (commands:run (commands:command-named 'transient-test/computed:show-menu))
  (test-user:settle)
  (check (transient-test:menu))
  (unload-owner! (module-owner '(transient-test computed)))
  (test-user:settle)
  (check-equal? '(#f #f) (list (transient-test:menu) (transient-test:popup-view))))

(commands:define-command (other) "Does nothing." (void))

(keys:bind! keys:global "C-c o" other)

(commands:define-command (show-plain) "Shows plain's keymap." (transient:show! transient-test/plain:keymap))

(test "a keymap no module defined as a menu stays open, empty, when its module unloads, until a key closes it"
  (commands:run show-plain)
  (test-user:settle)
  (check-equal? '((("h" "transient-test/plain:hello"))) (transient-test:menu))
  (unload-owner! (module-owner '(transient-test plain)))
  (test-user:settle)
  (check-equal? '() (transient-test:menu))
  (check-equal? '("Plain keys." "The keys of every open menu, searched after the top menu's keymap.")
                (map tables:documentation (list-head (keys:active-keymaps (test-user:client)) 2)))
  (test-user:press! "C-c o")
  (check-equal? #f (transient-test:menu)))

(test "the menus close when the menu's view leaves the layout"
  (test-user:press! "C-x 2")
  (let ([upper (layout:selected-view)])
    (test-user:press! "C-c m")
    (layout:delete-part! (layout:view-node upper))
    (test-user:settle)
    (check-equal? '(#f #f) (list (transient-test:menu) (transient-test:popup-view)))))

(test "a display rule may put the menu elsewhere, such as at the bottom of the screen, and closing it removes that part"
  (tables:set! layout:display-rules transient:buffer?
    (layout-split:display-at-side (layout:direction down) 95 'content '((locked . #t))))
  (let ([user-view (layout:selected-view)])
    (test-user:press! "C-c m")
    (check-equal? merge-menu-drawn (transient-test:menu))
    (check (layout:locked? (layout:view-node (transient-test:popup-view))))
    (check (eq? user-view (layout:selected-view)))
    (test-user:press! "C-g")
    (check-equal? '(#f #f) (list (transient-test:menu) (transient-test:popup-view))))
  (tables:remove! layout:display-rules transient:buffer?))

(test "when the plugin unloads, the menus close, its buffer goes, and the modules that import it unload"
  (test-user:press! "C-c m")
  (let ([old (map module-owner '((transient) (transient-test magit)))] [old-buffer (buffers:find " *transient*")])
    (unload-owner! (car old))
    (test-user:settle)
    (check-equal? '(#f (#f #f) #f) (list (transient-test:menu) (map owner-live? old) (buffers:live? old-buffer)))))
