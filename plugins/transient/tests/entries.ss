(import (tuna) (test) (test-runner) (test-user) (views) (buffers) (layout) (tables) (commands) (keys) (transient) (transient-test)
        (transient-test magit) (transient-test computed))

(define log '())

(commands:define-command (note [what 'none]) "Notes WHAT." (set! log (cons what log)))

(transient:define-menu m "A menu.")

(commands:define-command (show-m) "Shows m." (transient:show! m))

(keys:bind! keys:global "C-c t" show-m)

(define (raised-by who message)
  (lambda (c) (and (who-condition? c) (eq? who (condition-who c)) (message-condition? c) (string=? message (condition-message c)))))

(define (report-messages thunk)
  (map (lambda (c) (if (irritants-condition? c) (cons (condition-message c) (condition-irritants c)) (condition-message c)))
       (test-runner:reports-during thunk)))

(test-user:show! "|one\ntwo\n")

(test "entries under one heading join its group; groups show in the order of their first entry, entries in the order added; a heading may be #f"
  (transient:add! m "Actions" (transient:command "a" "Apply" note 'apply))
  (transient:add! m #f (transient:command "x" "Extra" note 'extra))
  (transient:add! m "Arguments" (transient:switch "- v" "Verbose" "--verbose"))
  (transient:add! m "Actions" (transient:command "b" "Build" note 'build))
  (test-user:press! "C-c t")
  (check-equal? '(("Actions" ("a" "Apply") ("b" "Build")) (("x" "Extra")) ("Arguments" ("- v" "Verbose" "--verbose")))
                (transient-test:menu)))

(test "each entry is clickable, and the menu, whose keymap binds the left button to keys:ignore, is inert"
  (let* ([lines (filter (lambda (l) (pair? (test-user:elements l "transient-menu"))) (test-user:elements (test-user:screen) "view-lines"))]
         [entry-nodes (filter (lambda (n) (and (pair? (test-user:elements n "transient-entry")) (= 1 (length (test-user:elements n "node")))))
                              (test-user:elements (car lines) "node"))])
    (check-equal? "inert" (test-user:element-attribute (car lines) "data-click"))
    (check-equal? '("clickable" "clickable" "clickable" "clickable")
                  (map (lambda (n) (test-user:element-attribute n "data-click")) entry-nodes))))

(test "each entry's key is bound in the menu to transient:press"
  (check-equal? (map (lambda (k) (cons k transient:press)) '("a" "x" "- v" "b")) (keys:bindings m)))

(test "an entry for a key the menu has replaces it and moves to the end of its heading's group"
  (transient:add! m "Arguments" (transient:command "a" "Again" note 'again))
  (test-user:settle)
  (check-equal? '((("x" "Extra")) ("Arguments" ("- v" "Verbose" "--verbose") ("a" "Again")) ("Actions" ("b" "Build")))
                (transient-test:menu))
  (test-user:press! "a")
  (check-equal? '(again) log))

(test "a module's entry replaces another's and adds a group; when it unloads, the entry it replaced comes back"
  (load-module! '(transient-test extra))
  (test-user:press! "C-c m")
  (check-equal? '("Merge" ("Arguments" ("- f" "Fast-forward only" "--ff-only") ("- n" "No fast-forward" "--no-ff") ("- s" "Strategy" "--strategy="))
                  ("Actions" ("m" "Squash instead")) ("More" ("s" "Squash")))
                (transient-test:menu))
  (test-user:press! "m")
  (check-equal? '() (transient-test/magit:merges))
  (unload-owner! (module-owner '(transient-test extra)))
  (test-user:press! "C-c m")
  (check-equal? '("Actions" ("m" "Merge")) (list-ref (transient-test:menu) 2))
  (test-user:press! "C-g"))

(test "remove! removes an entry and its key, whichever module added them"
  (test-user:press! "C-c t")
  (transient:remove! transient-test/magit:merge-menu "- s")
  (transient:remove! m "x")
  (test-user:settle)
  (check-equal? '(("Arguments" ("- v" "Verbose" "--verbose") ("a" "Again")) ("Actions" ("b" "Build"))) (transient-test:menu))
  (check-equal? '(#f #f) (list (tables:ref m "x" #f) (tables:ref transient-test/magit:merge-menu "- s" #f)))
  (test-user:press! "C-g"))

(define level 1)

(test "a description and a heading may be procedures, run at each draw; one that raises is reported once while the menu shows, and its part is left out"
  (transient:add! m (lambda () (string-append "Level " (number->string level)))
    (transient:command "l" (lambda () (string-append "Raise from " (number->string level))) note 'level))
  (transient:add! m "Broken" (transient:command "k" (lambda () (car '())) note 'broken))
  (check-equal? '(("~s is not a pair" ())) (report-messages (lambda () (test-user:press! "C-c t") (test-user:settle))))
  (check-equal? '(("Arguments" ("- v" "Verbose" "--verbose") ("a" "Again")) ("Actions" ("b" "Build")) ("Level 1" ("l" "Raise from 1")))
                (transient-test:menu))
  (set! level 2)
  (test-user:settle)
  (check-equal? '("Level 2" ("l" "Raise from 2")) (list-ref (transient-test:menu) 2))
  (test-user:press! "C-g"))

(test "a key bound in a menu with keys:bind! wins over its entry, shows in a last group, closes the menu and runs without the menu's arguments"
  (keys:bind! m "b" note)
  (test-runner:reports-during (lambda () (test-user:press! "C-c t")))
  (check-equal? '(("Arguments" ("- v" "Verbose" "--verbose") ("a" "Again")) ("Level 2" ("l" "Raise from 2")) (("b" "test-file/transient/entries:note")))
                (transient-test:menu))
  (test-user:press! "b")
  (check-equal? '(#f none) (list (transient-test:menu) (car log)))
  (keys:unbind! m "b")
  (transient:add! m "Actions" (transient:command "b" "Build" note 'build)))

(define names '("alpha" "beta"))

(test "a computed group's entries come from its procedure at each draw; an entry whose key is no printing character or one the menu has is left out, with a warning once per showing"
  (transient:add-computed! m "Computed"
    (lambda ()
      (append (map (lambda (name) (transient:command (substring name 0 1) name note (string->symbol name))) names)
              (list (transient:command "a" "Clash" note 'clash) (transient:command "zz" "Long" note 'long)
                    (transient:command "c" "Second c" note 'second)))))
  (let ([messages (report-messages (lambda () (test-user:press! "C-c t") (test-user:settle) (test-user:settle)))])
    (check-equal? '(("~s is not a pair" ()) "the computed entry a is left out: the menu has its key"
                    "the computed entry b is left out: the menu has its key"
                    "the computed entry zz is left out: its key is not one printing character")
                  messages))
  (check-equal? '("Computed" ("c" "Second c")) (list-ref (transient-test:menu) 3))
  (set! names '("gamma" "beta"))
  (test-user:settle)
  (check-equal? '("Computed" ("g" "gamma") ("c" "Second c")) (list-ref (transient-test:menu) 3))
  (test-user:press! "g")
  (check-equal? 'gamma (car log))
  (test-runner:reports-during (lambda () (test-user:press! "C-c t")))
  (check-equal? '("z is not in this menu") (report-messages (lambda () (test-user:press! "z"))))
  (check (transient-test:menu))
  (test-user:press! "C-g"))

(test "a second computed group with an equal heading replaces the first, which comes back when the replacer's module unloads"
  (commands:run transient-test/computed:show-menu)
  (test-user:settle)
  (check-equal? '(("Computed" ("p" "Original"))) (transient-test:menu))
  (load-module! '(transient-test recomputed))
  (test-user:settle)
  (check-equal? '(("Computed" ("q" "Replacement"))) (transient-test:menu))
  (test-user:press! "q")
  (check-equal? '(#f (replacement)) (list (transient-test:menu) (transient-test/computed:log)))
  (commands:run transient-test/computed:show-menu)
  (unload-owner! (module-owner '(transient-test recomputed)))
  (test-user:settle)
  (check-equal? '(("Computed" ("p" "Original"))) (transient-test:menu))
  (test-user:press! "C-g"))

(transient:define-menu hm "Headings.")

(test "a heading that is not a string is reported, named by the procedure given it"
  (transient:add! hm (lambda () 42) (transient:command "a" "A" note 'a))
  (transient:add! hm "Fine" (transient:command "b" "B" note 'b))
  (check-equal? '(("a title, heading or description that is not a string" 42))
                (report-messages (lambda () (transient:show! hm) (test-user:settle))))
  (check-equal? '(("Fine" ("b" "B"))) (transient-test:menu))
  (test-user:press! "C-g"))

(test "the procedures check what they are given"
  (check-raises (raised-by 'transient:add! "not a table") (transient:add! 'menu #f))
  (check-raises (raised-by 'transient:add! "neither a string, a procedure nor #f") (transient:add! m 'heading))
  (check-raises (raised-by 'transient:add! "not an entry") (transient:add! m #f 'entry))
  (check-raises (raised-by 'keys:bind! "not a valid key sequence") (transient:add! m #f (transient:command "C-" "Bad" note)))
  (check-raises (raised-by 'transient:add-computed! "not a procedure") (transient:add-computed! m #f 'entries))
  (check-raises (raised-by 'transient:remove! "not a string") (transient:remove! m 'x))
  (check-raises (raised-by 'transient:command "not a string") (transient:command 'k "K" note))
  (check-raises (raised-by 'transient:command "neither a string nor a procedure") (transient:command "k" 'k note))
  (check-raises (raised-by 'transient:command "not a command") (transient:command "k" "K" 'note))
  (check-raises (raised-by 'transient:staying-command "not a command") (transient:staying-command "k" "K" 'note))
  (check-raises (raised-by 'transient:switch "not a string") (transient:switch "k" "K" 'arg))
  (check-raises (raised-by 'transient:valued-switch "not a procedure") (transient:valued-switch "k" "K" "--k=" "reader"))
  (check-equal? '(#t #f) (map transient:entry? (list (transient:switch "k" "K" "--k") 'entry))))
