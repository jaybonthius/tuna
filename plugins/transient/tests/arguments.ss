(import (tuna) (test) (test-user) (views) (buffers) (layout) (options) (tables) (commands) (keys) (editing) (minibuffer)
        (transient) (transient-test) (transient-test magit) (minibuffer-test screen))

(define (merge-drawn f n s)
  (list "Merge" (list "Arguments" (list "- f" "Fast-forward only" f) (list "- n" "No fast-forward" n) (list "- s" "Strategy" s))
        '("Actions" ("m" "Merge"))))

(define plain (merge-drawn "--ff-only" "--no-ff" "--strategy="))

(define (report-messages thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (if (cancelled? c) 'cancelled (condition-message c)) reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(test-user:show! "|one\ntwo\n")

(define notes (views:buffer (layout:selected-view)))

(define todo (buffers:make "todo" "three\n"))

(test "a menu's arguments start from its option, read in the menu's view, each time it shows, so a buffer's local value applies"
  (check-equal? '() (transient:arguments transient-test/magit:merge-menu))
  (options:set! transient-test/magit:merge-arguments '("--no-ff"))
  (buffers:with-buffer todo (options:set-local! transient-test/magit:merge-arguments '("--ff-only")))
  (test-user:press! "C-c m")
  (check-equal? (merge-drawn "--ff-only" "*--no-ff" "--strategy=") (transient-test:menu))
  (test-user:press! "C-g")
  (views:set-buffer! (layout:selected-view) todo)
  (test-user:press! "C-c m")
  (check-equal? (merge-drawn "*--ff-only" "--no-ff" "--strategy=") (transient-test:menu))
  (test-user:press! "C-g")
  (views:set-buffer! (layout:selected-view) notes)
  (options:unset! transient-test/magit:merge-arguments)
  (check-equal? '() (transient:arguments transient-test/magit:merge-menu)))

(test "a switch puts its argument in or takes it out, and of an incompatible set one is in at a time"
  (test-user:press! "C-c m - f")
  (check-equal? (merge-drawn "*--ff-only" "--no-ff" "--strategy=") (transient-test:menu))
  (test-user:press! "- n")
  (check-equal? (merge-drawn "--ff-only" "*--no-ff" "--strategy=") (transient-test:menu))
  (test-user:press! "- n")
  (check-equal? plain (transient-test:menu))
  (test-user:press! "C-g"))

(transient:define-menu strategies "A menu of strategies." (incompatible ("--strategy=" "--ff-only")))

(transient:add! strategies #f (transient:switch "f" "Fast-forward only" "--ff-only")
  (transient:valued-switch "s" "Strategy" "--strategy=" (lambda (minibuffer-test/screen:questions) "ours")))

(commands:define-command (show-strategies) "Shows the strategies." (transient:show! strategies))

(test "a member of an incompatible set ending in = stands for that argument with any value"
  (commands:run show-strategies)
  (test-user:press! "f s")
  (check-equal? '((("f" "Fast-forward only" "--ff-only") ("s" "Strategy" "*--strategy=ours"))) (transient-test:menu))
  (test-user:press! "f")
  (check-equal? '((("f" "Fast-forward only" "*--ff-only") ("s" "Strategy" "--strategy="))) (transient-test:menu))
  (test-user:press! "C-g"))

(test "a valued switch reads its value, asking its description and :, and while the command chosen waits the menu stays open and takes no keys"
  (test-user:press! "C-c m - s")
  (check-equal? '("Strategy: ") (minibuffer-test/screen:questions))
  (test-user:press! "m")
  (check-equal? "m" (minibuffer:input (minibuffer:current-prompt)))
  (check (not (memq transient-test/magit:merge-menu (keys:active-keymaps (test-user:client)))))
  (check-equal? '("a command chosen in a menu is running") (report-messages (lambda () (transient-test:click-entry! "- f"))))
  (check-equal? plain (transient-test:menu))
  (test-user:press! "DEL")
  (test-user:type! "ours\n")
  (check-equal? (merge-drawn "--ff-only" "--no-ff" "*--strategy=ours") (transient-test:menu)))

(test "while a valued switch has a value, its key takes it out"
  (test-user:press! "- s")
  (check-equal? plain (transient-test:menu)))

(test "an empty answer puts in nothing, and C-g quits the prompt, the switch keeping its value"
  (test-user:press! "- s RET")
  (check-equal? plain (transient-test:menu))
  (test-user:press! "- s")
  (check-equal? '(cancelled) (report-messages (lambda () (test-user:press! "C-g"))))
  (check-equal? plain (transient-test:menu)))

(test "the command chosen reads the arguments set when it was chosen, and the menu has closed"
  (test-user:press! "- f m")
  (check-equal? '(("--ff-only")) (transient-test/magit:merges))
  (check-equal? #f (transient-test:menu)))

(transient:define-menu inner "An inner menu." (title "Inner"))

(commands:define-command (show-inner) "Shows the inner menu." (transient:show! inner))

(test "arguments are a menu's while it shows: a menu above leaves them as they are, and they start again at the next showing"
  (transient:add! transient-test/magit:merge-menu "Other" (transient:staying-command "i" "Inner" show-inner))
  (test-user:press! "C-c m - f i")
  (check-equal? '("Inner") (transient-test:menu))
  (test-user:press! "C-g")
  (check-equal? (append (merge-drawn "*--ff-only" "--no-ff" "--strategy=") '(("Other" ("i" "Inner")))) (transient-test:menu))
  (test-user:press! "C-g C-c m")
  (check-equal? (append plain '(("Other" ("i" "Inner")))) (transient-test:menu))
  (test-user:press! "C-g")
  (transient:remove! transient-test/magit:merge-menu "i"))

(test "argument-value gives a valued argument's value"
  (check-equal? "ours" (transient:argument-value '("--ff-only" "--strategy=ours") "--strategy="))
  (check-equal? #f (transient:argument-value '("--ff-only") "--strategy="))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'transient:argument-value (condition-who c)) (string=? "not a list of strings" (condition-message c))))
    (transient:argument-value '(1) "--strategy="))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'transient:argument-value (condition-who c)) (string=? "not a string" (condition-message c))))
    (transient:argument-value '() 'strategy)))

(test "when the plugin unloads while a valued switch's prompt waits, the command chosen quits, and the prompt goes"
  (test-user:press! "C-c m - s")
  (check-equal? '("Strategy: ") (minibuffer-test/screen:questions))
  (check-equal? '(cancelled) (report-messages (lambda () (unload-owner! (module-owner '(transient))) (test-user:settle))))
  (check-equal? '(#f #f) (list (transient-test:menu) (minibuffer:current-prompt))))
