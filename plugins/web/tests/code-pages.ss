(import (tuna) (test) (web) (haml) (hooks) (tables))

(define seen '())
(define (note! x) (set! seen (cons x seen)))
(define (taken!)
  (let ([l (reverse seen)])
    (set! seen '())
    l))

(define (open-noting name)
  (set! seen '())
  (web:open-client
    (lambda (client screen title) (note! (list name 'screen title)))
    (lambda (client call value) (note! (list name 'call call value)))
    (lambda (client question value) (note! (list name 'ask question value)) (vector "answer" value))))

;; A file of web's tests imports no plugin above web, since layout's own
;; draws would reach every code page a test opens.
(define (settle)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

(define (paused-asker client name value)
  (let ([t (spawn-task (lambda (restore) (web:ask-page client name value)))])
    (settle)
    t))

(define (task-values t)
  (let-values ([(how detail) (join-task t)])
    (check-equal? 'returned how)
    detail))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (settle)
    (advice-remove! report keep)
    (map condition-message (reverse reported))))

(test "a code page's client is listed by web:clients, after the clients before it, and client-added runs as it opens"
  (let* ([added '()] [entry (lambda (c) (set! added (cons c added)))])
    (hooks:add! web:client-added entry)
    (let* ([a (open-noting 'a)] [b (open-noting 'b)])
      (hooks:remove! web:client-added entry)
      (check (web:client? a))
      (check-equal? (list a b) (web:clients))
      (check-equal? (list b a) added)
      (web:close-client! a)
      (web:close-client! b))))

(test "a screen is received as given, with its title, as the opener, unless its bytes and title equal the last ones"
  (let* ([o (make-owner '(code-pages opener))]
         [c (call-as-owner o
              (lambda ()
                (web:open-client
                  (lambda (client screen title) (note! (list (current-owner) screen title)))
                  (lambda (client call value) (void))
                  (lambda (client question value) 'null))))]
         [one (haml (:p "one"))]
         [two (string->utf8 "<p>two</p>")])
    (web:send-screen! c one "One")
    (web:send-screen! c (haml (:p "one")) "One")
    (web:send-screen! c (haml (:p "one")) "Also one")
    (web:send-screen! c two "Two")
    (web:send-screen! c (string->utf8 "<p>two</p>") "Two")
    (let ([received (taken!)])
      (check-equal? (list (list o "One") (list o "Also one") (list o "Two"))
                    (map (lambda (e) (list (car e) (caddr e))) received))
      (check (eq? one (cadr (car received))))
      (check (eq? two (cadr (caddr received)))))
    (unload-owner! o)))

(test "web:wait-for-applied returns at once for a code page, which applies a screen as it receives it"
  (let ([c (open-noting 'a)])
    (web:send-screen! c (haml (:p "one")) "One")
    (web:wait-for-applied c)
    (check-equal? 1 (length (taken!)))
    (web:close-client! c)))

(test "calls are received in the order made, on the main thread, a call from another thread in a task of its own"
  (let* ([main (get-thread-id)]
         [c (web:open-client
              (lambda (client screen title) (void))
              (lambda (client call value) (note! (list call value (= main (get-thread-id)))))
              (lambda (client question value) #f))])
    (web:call-page! c "first" 1)
    (web:call-page! c "second" '#("two"))
    (join-task (fork-task (lambda (restore) (web:call-page! c "third" 3))))
    (settle)
    (check-equal? '(("first" 1 #t) ("second" #("two") #t) ("third" 3 #t)) (taken!))
    (web:close-client! c)))

(test "a question is answered after the next screen given, and the asking task gets the answer"
  (let* ([c (open-noting 'a)] [asker (paused-asker c "size" 5)])
    (check-equal? 'paused (task-state asker))
    (check-equal? '() (taken!))
    (web:send-screen! c (haml (:p "one")) "One")
    (check-equal? '(#("answer" 5)) (task-values asker))
    (check-equal? '((a screen "One") (a ask "size" 5)) (taken!))
    (web:close-client! c)))

(test "a question about an unchanged screen is answered all the same"
  (let ([c (open-noting 'a)])
    (web:send-screen! c (haml (:p "one")) "One")
    (let ([asker (paused-asker c "size" 6)])
      (web:send-screen! c (haml (:p "one")) "One")
      (check-equal? '(#("answer" 6)) (task-values asker)))
    (web:close-client! c)))

(test "a question to a closed client is answered #f"
  (let ([c (open-noting 'a)])
    (web:close-client! c)
    (check-equal? #f (web:ask-page c "size" 1))))

(test "a raise in receive-screen is reported, the client is closed and client-removed runs, and a waiting question gets #f"
  (let* ([removed '()] [entry (lambda (c) (set! removed (cons c removed)))]
         [c (web:open-client (lambda (client screen title) (error 'page "cannot draw"))
                             (lambda (client call value) (void))
                             (lambda (client question value) 'null))]
         [asker (paused-asker c "size" 1)])
    (hooks:add! web:client-removed entry)
    (check-equal? '("cannot draw") (reports-during (lambda () (web:send-screen! c (haml (:p "one")) "One"))))
    (hooks:remove! web:client-removed entry)
    (check-equal? '(#f) (task-values asker))
    (check (not (memq c (web:clients))))
    (check-equal? (list c) removed)))

(test "a raise in receive-call is reported and closes the client"
  (let ([c (web:open-client (lambda (client screen title) (void))
                            (lambda (client call value) (error 'page "no such call"))
                            (lambda (client question value) 'null))])
    (check-equal? '("no such call") (reports-during (lambda () (web:call-page! c "missing" 1))))
    (check (not (memq c (web:clients))))))

(test "a raise in answer is reported and closes the client, and the asking task gets #f"
  (let* ([c (web:open-client (lambda (client screen title) (void))
                             (lambda (client call value) (void))
                             (lambda (client question value) (error 'page "cannot answer")))]
         [asker (paused-asker c "size" 1)])
    (check-equal? '("cannot answer") (reports-during (lambda () (web:send-screen! c (haml (:p "one")) "One"))))
    (check-equal? '(#f) (task-values asker))
    (check (not (memq c (web:clients))))))

(test "calls, questions and answers cross as JSON, as they do to a browser page"
  (let* ([received '()]
         [c (web:open-client
              (lambda (client screen title) (void))
              (lambda (client call value) (set! received (cons value received)))
              (lambda (client question value) (set! received (cons value received)) (list (cons "got" value))))]
         [asker (paused-asker c "size" '(("n" . 1) ("list" . #(1 2))))])
    (web:call-page! c "show" '#(1 "two" #t null))
    (web:send-screen! c (haml (:p "one")) "One")
    (check-equal? '((("got" . (("n" . 1) ("list" . #(1 2)))))) (task-values asker))
    (check-equal? '(#(1 "two" #t null) (("n" . 1) ("list" . #(1 2)))) (reverse received))
    (web:close-client! c)))

(test "an answer JSON cannot write is a raise of the page: reported, the client closed, the asking task given #f"
  (let* ([c (web:open-client (lambda (client screen title) (void))
                             (lambda (client call value) (void))
                             (lambda (client question value) car))]
         [asker (paused-asker c "size" 1)])
    (check-equal? 1 (length (reports-during (lambda () (web:send-screen! c (haml (:p "one")) "One")))))
    (check-equal? '(#f) (task-values asker))
    (check (not (memq c (web:clients))))))

(test "web:close-client! removes the client and runs client-removed; closing it again does nothing"
  (let* ([removed '()] [entry (lambda (c) (set! removed (cons c removed)))] [c (open-noting 'a)])
    (hooks:add! web:client-removed entry)
    (web:close-client! c)
    (web:close-client! c)
    (hooks:remove! web:client-removed entry)
    (check-equal? (list c) removed)
    (check (not (memq c (web:clients))))
    (web:call-page! c "after" 1)
    (web:send-screen! c (haml (:p "after")) "After")
    (check-equal? '() (taken!))))

(test "a code page's client closes when the owner that opened it unloads"
  (let* ([o (make-owner '(code-pages unloading))] [c (call-as-owner o (lambda () (open-noting 'a)))])
    (unload-owner! o)
    (check (not (memq c (web:clients))))))

(test "web:post-input! runs items through web:input-handlers in order, with the client current"
  (let ([c (open-noting 'a)])
    (tables:set! web:input-handlers "number"
      (lambda (client item) (note! (list (eq? client (web:current-client)) (cdr (assoc "n" item))))))
    (for-each (lambda (n) (web:post-input! c (list (cons "type" "number") (cons "n" n)))) '(1 2 3))
    (settle)
    (check-equal? '((#t 1) (#t 2) (#t 3)) (taken!))
    (tables:remove! web:input-handlers "number")
    (web:close-client! c)))

(test "an item marked as a quit cancels the client's item paused for anything but its input, with the reason quit"
  (let ([c (open-noting 'a)])
    (tables:set! web:input-handlers "wait"
      (lambda (client item)
        (guard (e [(cancelled? e) (note! (list 'cancelled (cancelled-reason e)))])
          (suspend (lambda (resume) (void))))))
    (tables:set! web:input-handlers "other" (lambda (client item) (note! 'other)))
    (web:post-input! c '(("type" . "wait")))
    (settle)
    (web:post-input! c '(("type" . "other") ("quit" . #t)))
    (settle)
    (check-equal? '((cancelled quit) other) (taken!))
    (tables:remove! web:input-handlers "wait")
    (tables:remove! web:input-handlers "other")
    (web:close-client! c)))

(test "a quit item cancels no item paused in web:suspend-for-input, which takes the quit as input in its turn"
  (let ([c (open-noting 'a)] [reader #f])
    (tables:set! web:input-handlers "read"
      (lambda (client item)
        (guard (e [(cancelled? e) (note! (list 'cancelled (cancelled-reason e)))])
          (note! (web:suspend-for-input (lambda (resume) (set! reader resume)))))))
    (tables:set! web:input-handlers "key"
      (lambda (client item) (reader (lambda () (cdr (assoc "name" item))))))
    (web:post-input! c '(("type" . "read")))
    (settle)
    (web:post-input! c '(("type" . "key") ("name" . "C-g") ("quit" . #t)))
    (settle)
    (check-equal? '("C-g") (taken!))
    (check-raises (lambda (e) (and (who-condition? e) (eq? 'web:suspend-for-input (condition-who e))))
      (web:suspend-for-input 'receiver))
    (tables:remove! web:input-handlers "read")
    (tables:remove! web:input-handlers "key")
    (web:close-client! c)))

;; The spinning item holds the main thread, so the quit comes from a
;; thread of its own, as a page's would; a second quit, should the first
;; not end the item within 5 s, lets the test end and fail.
(define (spin-and-quit! c post-spin!)
  (let ([spun #f] [reported '()])
    (define (ended?) (and spun (eq? 'done (task-state spun))))
    (define (keep next e) (set! reported (cons e reported)))
    (define (pause-thread ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))
    (tables:set! web:input-handlers "spin" (lambda (client item) (set! spun (current-task)) (let loop () (loop))))
    (tables:set! web:input-handlers "other" (lambda (client item) (note! 'other)))
    (advice-add! report keep)
    (fork-task
      (lambda (restore)
        (let wait () (unless spun (pause-thread 1) (wait)))
        (web:post-input! c '(("type" . "other") ("quit" . #t)))
        (let wait ([ms 0])
          (cond
            [(ended?) (void)]
            [(< ms 5000) (pause-thread 10) (wait (+ ms 10))]
            [else (web:post-input! c '(("type" . "other") ("quit" . #t)))]))))
    (post-spin!)
    (let wait () (unless (ended?) (settle) (wait)))
    (settle)
    (advice-remove! report keep)
    (tables:remove! web:input-handlers "spin")
    (tables:remove! web:input-handlers "other")
    (let-values ([(how detail) (join-task spun)])
      (list how detail (map cancelled? reported)))))

(test "a quit item cancels the code page's item that is running, not only one that pauses, at the first quit"
  (let ([c (open-noting 'a)])
    (check-equal? '(cancelled quit (#t))
      (spin-and-quit! c (lambda () (web:post-input! c '(("type" . "spin"))))))
    (check-equal? '(other) (taken!))
    (web:close-client! c)))

(test "items that wait behind a question run after the answer in order, each in its turn: one that raises is reported and the rest run"
  (let ([c (open-noting 'a)])
    (tables:set! web:input-handlers "ask" (lambda (client item) (note! (web:ask-page client "size" 1))))
    (tables:set! web:input-handlers "fail" (lambda (client item) (note! 'fail) (car '())))
    (tables:set! web:input-handlers "note" (lambda (client item) (note! (cdr (assoc "n" item)))))
    (web:post-input! c '(("type" . "ask")))
    (settle)
    (for-each (lambda (item) (web:post-input! c item)) '((("type" . "note") ("n" . 1)) (("type" . "fail")) (("type" . "note") ("n" . 2))))
    (settle)
    (check-equal? '() (taken!))
    (check-equal? '("~s is not a pair")
      (reports-during
        (lambda ()
          (web:send-screen! c (haml (:p "one")) "One")
          (settle))))
    (check-equal? '((a screen "One") (a ask "size" 1) #("answer" 1) 1 fail 2) (taken!))
    (web:post-input! c '(("type" . "note") ("n" . 3)))
    (settle)
    (check-equal? '(3) (taken!))
    (for-each (lambda (type) (tables:remove! web:input-handlers type)) '("ask" "fail" "note"))
    (web:close-client! c)))

(test "a quit item cancels a running item that waited behind a question, at the first quit"
  (let ([c (open-noting 'a)])
    (tables:set! web:input-handlers "ask" (lambda (client item) (web:ask-page client "size" 1)))
    (web:post-input! c '(("type" . "ask")))
    (settle)
    (check-equal? '(cancelled quit (#t))
      (spin-and-quit! c
        (lambda ()
          (web:post-input! c '(("type" . "spin")))
          (settle)
          (web:send-screen! c (haml (:p "one")) "One"))))
    (check-equal? '((a screen "One") (a ask "size" 1) other) (taken!))
    (tables:remove! web:input-handlers "ask")
    (web:close-client! c)))

(test "web:post-input! takes only an item for an open client web:open-client opened"
  (let ([c (open-noting 'a)] [raised-by (lambda (who) (lambda (e) (and (who-condition? e) (eq? who (condition-who e)))))])
    (check-raises (raised-by 'web:post-input!) (web:post-input! c '(("type" . "x") 1)))
    (check-raises (raised-by 'web:post-input!) (web:post-input! c '((type . "x"))))
    (check-raises (raised-by 'web:post-input!) (web:post-input! c (list (cons "type" "x") (cons "v" car))))
    (check-raises (raised-by 'web:post-input!) (web:post-input! 'client '(("type" . "x"))))
    (web:close-client! c)
    (check-raises (raised-by 'web:post-input!) (web:post-input! c '(("type" . "x"))))
    (check-raises (raised-by 'web:open-client) (web:open-client void void 'answer))
    (check-raises (raised-by 'web:close-client!) (web:close-client! 'client))
    (check-raises (raised-by 'web:wait-for-applied) (web:wait-for-applied 'client))))
