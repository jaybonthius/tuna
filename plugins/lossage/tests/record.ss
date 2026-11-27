(import (tuna) (test) (test-user) (web) (views) (layout) (hooks) (options) (commands) (keys) (lossage) (lossage-test mouse)
        (command-picker))

(load-module! '(lossage-test))

(define (bind-honks!)
  (let ([honk (commands:command-named 'lossage-test:honk)] [honk-twice (commands:command-named 'lossage-test:honk-twice)])
    (keys:bind! keys:global "<f5>" honk)
    (keys:bind! keys:global "C-c h" honk-twice)
    (keys:bind! keys:global "<mouse-8>" honk)
    (keys:bind! keys:global "<down-mouse-8>" honk)
    (keys:bind! keys:global "<mouse-movement>" honk)))

(bind-honks!)

(define mark 0)

(define (mark!) (set! mark (length (lossage:recent-keys))))

(define (since-mark) (list-tail (lossage:recent-keys) mark))

(options:set! lossage:size 1000)

(test "the record holds each key as it arrives, and each command by its name after the keys that ran it, oldest first"
  (mark!)
  (test-user:press! "C-c h <f5>")
  (check-equal? '("C-c" "h" lossage-test:honk-twice "<f5>" lossage-test:honk) (since-mark)))

(test "a mouse key is recorded by its key, without its position; mouse movements are not, though the command one runs is"
  (test-user:show! "|0123456789")
  (mark!)
  (lossage-test/mouse:mouse! "down" 8 '() 0)
  (lossage-test/mouse:mouse! "move" 8 '() 2)
  (lossage-test/mouse:mouse! "move" 8 '("shift") 3)
  (lossage-test/mouse:mouse! "click" 8 '() 3)
  (check-equal? '("<down-mouse-8>" lossage-test:honk lossage-test:honk lossage-test:honk "<mouse-8>" lossage-test:honk) (since-mark)))

(test "every client's keys go in one record, in the order they came, each prefix as it is typed"
  (let ([other (test-user:open-client)])
    (mark!)
    (test-user:press! "C-c")
    (test-user:press! other "<f5>")
    (test-user:press! "h")
    (check-equal? '("C-c" "<f5>" lossage-test:honk "h" lossage-test:honk-twice) (since-mark))
    (web:close-client! other)))

(test "a key no keymap binds is recorded, with the command that says so"
  (mark!)
  (let ([reported '()])
    (let ([keep (lambda (next c) (set! reported (cons c reported)))])
      (advice-add! report keep)
      (test-user:press! "C-c z")
      (advice-remove! report keep))
    (check-equal? '("C-c z is undefined") (map condition-message reported)))
  (check-equal? '("C-c" "z" keys:undefined) (since-mark)))

(test "only the outermost command is recorded: not the commands it runs, nor the command M-x runs; keys typed into a prompt are there"
  (mark!)
  (test-user:press! "M-x")
  (test-user:type! "lossage-test:honk")
  (test-user:press! "RET")
  (let ([record (since-mark)])
    (check-equal? '("M-x" command-picker:execute-extended-command "l") (list-head record 3))
    (check-equal? '("RET" completion:exit) (list-tail record (- (length record) 2)))
    (check (not (memq 'lossage-test:honk record)))))

(test "a command run other than by a key is recorded too"
  (mark!)
  (commands:run (commands:command-named 'lossage-test:honk))
  (check-equal? '(lossage-test:honk) (since-mark)))

(test "a command stays named once its module has unloaded"
  (mark!)
  (commands:run (commands:command-named 'lossage-test:honk))
  (unload-owner! (module-owner '(lossage-test)))
  (check-equal? #f (commands:command-named 'lossage-test:honk))
  (check-equal? '(lossage-test:honk) (since-mark))
  (load-module! '(lossage-test))
  (bind-honks!))

(test "the record keeps the newest lossage:size keys and commands; lowering the size drops the rest at once, so raising it brings none back"
  (test-user:press! "<f5>")
  (options:set! lossage:size 3)
  (check-equal? '(lossage-test:honk "<f5>" lossage-test:honk) (lossage:recent-keys))
  (options:set! lossage:size 6)
  (check-equal? '(lossage-test:honk "<f5>" lossage-test:honk) (lossage:recent-keys))
  (test-user:press! "<f5> C-c h")
  (check-equal? '(lossage-test:honk "<f5>" lossage-test:honk "C-c" "h" lossage-test:honk-twice) (lossage:recent-keys)))

(test "only the setting bounds the record, not a binding or a buffer's local value"
  (options:with ([lossage:size 1]) (keys:press! (test-user:client) "<f5>"))
  (check-equal? '("C-c" "h" lossage-test:honk-twice "<f5>" lossage-test:honk) (list-tail (lossage:recent-keys) 1))
  (views:call-with-view (layout:selected-view) (lambda () (options:set-local! lossage:size 2)))
  (test-user:press! "<f5>")
  (check-equal? 6 (length (lossage:recent-keys)))
  (views:call-with-view (layout:selected-view) (lambda () (options:unset-local! lossage:size)))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'options:set! (condition-who c)))) (options:set! lossage:size 0))
  (check-equal? 6 (lossage:size)))

(test "a key is recorded before press! reads it, so a key it refuses is recorded too"
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'keys:press! (condition-who c)))) (keys:press! (test-user:client) "C-"))
  (check-equal? "C-" (car (last-pair (lossage:recent-keys)))))

(test "the record can be read on another thread"
  (let ([read #f])
    (join-task (fork-task (lambda (restore) (set! read (lossage:recent-keys)))))
    (check-equal? (lossage:recent-keys) read)))

(test "reloading keys or commands reloads lossage, whose record starts empty"
  (reload-modules! '((keys)))
  (check-equal? '() (lossage:recent-keys))
  (test-user:press! "<f5>")
  (check-equal? '("<f5>" lossage-test:honk) (lossage:recent-keys))
  (reload-modules! '((commands)))
  (check-equal? '() (lossage:recent-keys))
  (bind-honks!)
  (test-user:press! "<f5>")
  (check-equal? '("<f5>" lossage-test:honk) (lossage:recent-keys)))

(test "unloading it takes back its advice and its hook entry"
  (let ([old (module-owner '(lossage))] [entries (length (hooks:entries commands:before-command))])
    (unload-owner! old)
    (check-equal? #f (owner-live? old))
    (check-equal? #f (exists (lambda (c) (eq? (car c) old)) (definition-changes keys:press!)))
    (check-equal? (- entries 1) (length (hooks:entries commands:before-command)))))
