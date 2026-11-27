(import (tuna) (test) (test-browser) (test-user) (test-runner) (web) (keys) (commands) (cdp) (cdp page) (layout) (editing)
        (echo-area) (minibuffer) (command-picker) (completion))

(define page (test-browser:open))

(define waiting #f)

(commands:define-command (wait-for-ever)
  "Pauses until cancelled."
  (guard (e [(cancelled? e) (set! waiting (list 'cancelled (cancelled-reason e)))])
    (set! waiting 'paused)
    (suspend (lambda (resume) (void)))))

(keys:bind! keys:global "C-c w" wait-for-ever)

(define (texts selector) (test-browser:call (lambda () (map element-text (page-query page selector)))))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (map (lambda (c) (if (cancelled? c) (list 'cancelled (cancelled-reason c)) (condition-message c))) (reverse reported))))

(test "a page opened is a client of web, and has applied its first screen when open returns"
  (let* ([before (web:clients)] [other (test-browser:open)] [added (remp (lambda (c) (memq c before)) (web:clients))])
    (check-equal? 1 (length added))
    (check-equal? 1 (length (test-browser:call (lambda () (page-query other "#screen .layout-screen")))))
    (test-browser:close! other)
    (test-runner:wait-until (lambda () (not (memq (car added) (web:clients)))))))

(test "keys pressed in the page reach Tuna as a keyboard's, in Tuna's notation"
  (test-user:show! "one two|")
  (test-browser:press! page "C-a M-f C-k")
  (check-equal? "one|" (test-user:text))
  (test-browser:press! page "<left> <left> DEL C-e RET")
  (check-equal? "ne\n|" (test-user:text)))

(test "typed text reaches Tuna character by character, shifted characters and spaces included"
  (test-user:show! "|")
  (test-browser:type! page "Hi, there! (x_y)\nZ")
  (check-equal? "Hi, there! (x_y)\nZ|" (test-user:text)))

(test "the page has applied what Tuna drew by the time a press returns"
  (test-browser:press! page "M-x")
  (check-equal? '("M-x ") (texts ".minibuffer-question")))

(test "a quit key typed at a prompt is read as a key, whose binding ends the prompt; the page shows it gone and Quit"
  (check-equal? '((cancelled #f)) (reports-during (lambda () (test-browser:press! page "C-g"))))
  (check-equal? '() (texts ".minibuffer-question"))
  (check-equal? '("Quit") (texts ".echo-area-message")))

(test "a quit key the page marks as a quit stops a command paused for anything but input"
  (test-browser:press! page "C-c w")
  (check-equal? 'paused waiting)
  (test-browser:press! page "C-g")
  (check-equal? '(cancelled quit) waiting))

(test "wait-for-applied returns once the page shows what Tuna drew after a change made from Scheme"
  (echo-area:message! "Drawn")
  (test-browser:wait-for-applied page)
  (check-equal? '("Drawn") (texts ".echo-area-message")))

(test "a key no keyboard has, and a page test-browser did not open, raise"
  (check-raises assertion-violation? (test-browser:press! page "<mouse-1>"))
  (check-raises assertion-violation? (test-browser:press! 'page "a"))
  (check-raises assertion-violation? (test-browser:type! page 'text)))
