(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (layout) (layout-split) (views) (buffers) (document) (keys) (commands) (options) (faces) (ask) (editing)
        (echo-area) (echo-area-test) (poker) (lines))

(define view echo-area-test:view)
(define messages echo-area-test:messages)

(define other (test-user:open-client))

(define seen 'none)

(commands:define-command (peek) "Notes the message as the command starts." (set! seen (echo-area:current-message)))
(commands:define-command (say) "Says hello." (echo-area:message! "Hello"))

(keys:bind! keys:global "C-c p" peek)
(keys:bind! keys:global "C-c s" say)

(test "a message shows on every client until the next typed key from any client, which clears it before its command runs"
  (echo-area:message! "First")
  (test-user:settle)
  (check-equal? '("First" "First") (list (echo-area-test:echo) (echo-area-test:echo other)))
  (test-user:press! other "C-c p")
  (check-equal? '(#f #f #f) (list seen (echo-area:current-message) (echo-area-test:echo)))
  (test-user:press! "C-c s")
  (check-equal? "Hello" (echo-area:current-message)))

(test "a click does not clear the message"
  (views:set-buffer! (view) (buffers:make "notes" "one\ntwo\nthree\n"))
  (echo-area-test:click-at! (view) 5)
  (check-equal? '(5 "Hello") (list (views:point (view)) (echo-area:current-message))))

(test "a message of \"\" clears the echo area at once, which keeps its element, and logs nothing"
  (let ([before (messages)])
    (echo-area:message! "")
    (test-user:settle)
    (check-equal? (list #f before) (list (echo-area:current-message) (messages)))
    (let ([e (echo-area-test:element)])
      (check-equal? '("status" #f) (list (test-user:element-attribute e "role") (test-user:element-attribute e "data-face"))))))

(test "each message is logged; an equal one counts on the last line, and one of several lines takes several lines"
  (for-each (lambda (m) (echo-area:message! m)) '("Saved" "Saved" "Saved" "two~%lines" "two~%lines"))
  (check-equal? "two\nlines" (echo-area:current-message))
  (check-equal? '("First" "Hello" "Saved [3 times]" "two" "lines [2 times]")
    (list-tail (echo-area-test:log-lines) (- (length (echo-area-test:log-lines)) 5))))

(test "the log keeps echo-area:log-max lines, the oldest going first"
  (options:set! echo-area:log-max 3)
  (echo-area:message! "Next")
  (check-equal? "two\nlines [2 times]\nNext\n" (messages))
  (echo-area:message! "Next")
  (check-equal? "two\nlines [2 times]\nNext [2 times]\n" (messages))
  (options:set! echo-area:log-max 1000))

(test "*Messages* refuses the user's edits and never reads as modified; the echo area cannot be killed; a killed log is made again by the next message"
  (let ([log (buffers:find "*Messages*")])
    (check-raises (echo-area-test:raised? 'buffers:replace! "the node refuses the edit") (buffers:replace! log 1 1 "x"))
    (check-equal? '(#f #f #t) (list (buffers:modified? log) (buffers:kill! (echo-area-test:echo-buffer)) (buffers:kill! log)))
    (check-equal? #f (buffers:find "*Messages*"))
    (echo-area:message! "After")
    (check-equal? "After\n" (messages))
    (check-equal? '(#t #t) (map buffers:silent? (list (echo-area-test:echo-buffer) (buffers:find "*Messages*"))))))

(test "a command that kills *Messages* asks nothing, since it reads as unmodified"
  (commands:define-command (kill [buffer (buffers:current)]) "Kills BUFFER." (buffers:kill! buffer))
  (commands:run kill (buffers:find "*Messages*"))
  (check-equal? #f (buffers:find "*Messages*"))
  (echo-area:message! "After"))

(test "a click on the echo area shows *Messages* in another view without selecting it, its point at the end; C-h e does the same"
  (layout-split:split-view! (view) (layout-split:direction column))
  (let ([selected (view)])
    (echo-area-test:click-at! (echo-area-test:echo-view) 1)
    (check (eq? (view) selected))
    (let ([shown (find (lambda (v) (eq? (views:buffer v) (buffers:find "*Messages*"))) (layout:views))])
      (check-equal? (- (document:length (buffers:document (buffers:find "*Messages*"))) 1) (views:point shown))))
  (check-equal? "After" (echo-area:current-message))
  (check (eq? echo-area:show-messages (keys:lookup (test-user:client) "C-h e"))))

(test "the echo area's keymap shows the log on a click and ignores the press, and is its kind's keymap"
  (check-equal? '(("<mouse-1>" . echo-area:show-messages) ("<down-mouse-1>" . keys:ignore))
    (map (lambda (b) (cons (car b) (commands:command-name (cdr b)))) (keys:bindings echo-area:keymap)))
  (check (eq? echo-area:keymap (buffers:kind-keymap (buffers:constructor-kind echo-area:area)))))

(test "message!, current-message and current-face work on the main thread only, and the arguments are checked"
  (check-equal? '(echo-area:message! "not on the main thread") (echo-area-test:on-thread (lambda () (echo-area:message! "From a thread"))))
  (check-equal? '(echo-area:current-message "not on the main thread") (echo-area-test:on-thread echo-area:current-message))
  (check-equal? '(echo-area:current-face "not on the main thread") (echo-area-test:on-thread echo-area:current-face))
  (check-raises (echo-area-test:raised? 'echo-area:message! "not a string") (echo-area:message! 'hello))
  (check-raises (echo-area-test:raised? 'echo-area:face "not a face or #f") (parameterize ([echo-area:face "red"]) #t))
  (check-raises (lambda (c) (assertion-violation? c)) (options:set! echo-area:log-max -1)))

(test "a killed log made again by another module's code is silent after that module unloads, and so is one made by code acting for no module"
  (buffers:kill! (buffers:find "*Messages*"))
  (poker:poke)
  (unload-owner! (module-owner '(poker)))
  (check-equal? (list "Poked\n" #t) (list (messages) (buffers:silent? (buffers:find "*Messages*"))))
  (buffers:kill! (buffers:find "*Messages*"))
  (let* ([late? #t] [late (lambda (ended) (ended) (when late? (set! late? #f) (echo-area:message! "Late")))])
    (advice-add! batch-ended late)
    (test-user:settle)
    (advice-remove! batch-ended late))
  (check-equal? (list "Late\n" #t) (list (messages) (buffers:silent? (buffers:find "*Messages*")))))

(test "advised to return #t, hidden? makes the echo area draw nothing, while messages show, are logged and are cleared as before"
  (check-equal? #f (echo-area:hidden?))
  (let ([hide (lambda (hidden?) #t)])
    (advice-add! echo-area:hidden? hide)
    (echo-area:message! "Hidden")
    (test-user:settle)
    (check-equal? (list "Hidden" #f "Late\nHidden\n") (list (echo-area:current-message) (echo-area-test:element) (messages)))
    (test-user:press! "C-a")
    (check-equal? #f (echo-area:current-message))
    (advice-remove! echo-area:hidden? hide))
  (test-user:settle)
  (check (echo-area-test:element)))

(test "current-face is the face the message was shown in, or #f, and the element carries it"
  (echo-area:message! "Plain")
  (check-equal? #f (echo-area:current-face))
  (parameterize ([echo-area:face faces:error]) (echo-area:message! "Failed"))
  (check-equal? 'error (echo-area:current-face))
  (test-user:settle)
  (check-equal? "error" (test-user:element-attribute (echo-area-test:element) "data-face"))
  (echo-area:message! "")
  (check-equal? #f (echo-area:current-face)))

(test "the documented examples of message!, face, current-face, hidden? and log-max hold"
  (echo-area:message! "Wrote ~a" "/home/jay/notes.org")
  (check-equal? "Wrote /home/jay/notes.org" (echo-area:current-message))
  (echo-area:message! "")
  (check-equal? #f (echo-area:current-message))
  (parameterize ([echo-area:face faces:warning])
    (echo-area:message! "~a is larger than 10 MB" "server.log"))
  (test-user:settle)
  (check-equal? '("server.log is larger than 10 MB" "warning")
    (list (test-user:element-text (echo-area-test:element)) (test-user:element-attribute (echo-area-test:element) "data-face")))
  (parameterize ([echo-area:face faces:error]) (echo-area:message! "Disk full"))
  (check-equal? 'error (echo-area:current-face))
  (let ([before (echo-area-test:last-logged)])
    (options:with ([echo-area:log-max 0]) (echo-area:message! "Not logged"))
    (check-equal? (list "Not logged" before) (list (echo-area:current-message) (echo-area-test:last-logged)))))

(test "the what-line example says which line point is on"
  (views:set-buffer! (view) (buffers:make "lines" "one\ntwo\nthree\n"))
  (views:set-point! (view) 6)
  (views:with-view (view) (commands:run lines:what-line))
  (check-equal? "Line 2" (echo-area:current-message)))

(test "advice on message! sees every message, reports included, with the face each shows in"
  (let* ([seen '()]
         [note (lambda (message format-string . vs)
                 (apply message format-string vs)
                 (set! seen (cons (list (echo-area:current-message) (echo-area:face)) seen)))])
    (advice-add! echo-area:message! note)
    (echo-area:message! "Saved ~a" "notes")
    (check-equal? '(car) (map condition-who (echo-area-test:reports-during (lambda () (spawn-task (lambda (restore) (car '()))) (test-user:settle)))))
    (advice-remove! echo-area:message! note)
    (check-equal? '(("Saved notes" #f) ("() is not a pair" error)) (reverse seen))))

(test "the echo area shows what ask:message tells, as a message"
  (ask:message "Deleted 2 files")
  (check-equal? "Deleted 2 files" (echo-area:current-message)))

(test "echo-area:spans draws ranges of the text in faces inside the message's, the log keeps the text alone, and a range is cut to the text"
  (parameterize ([echo-area:spans (list (list 6 23 faces:highlight))])
    (echo-area:message! "~a" "total(items: list[Item]) -> Decimal"))
  (test-user:settle)
  (let ([faced (test-user:elements-with (echo-area-test:element) "data-face")])
    (check-equal? '(("highlight" "items: list[Item]"))
      (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e))) faced)))
  (check-equal? (list '((6 23 highlight)) "total(items: list[Item]) -> Decimal")
    (list (echo-area:current-spans) (echo-area-test:last-logged)))
  (parameterize ([echo-area:spans (list (list 2 99 faces:warning))])
    (echo-area:message! "short"))
  (check-equal? '((2 5 warning)) (echo-area:current-spans))
  (echo-area:message! "plain")
  (check-equal? '() (echo-area:current-spans))
  (echo-area:message! "")
  (check-equal? '() (echo-area:current-spans))
  (check-raises (echo-area-test:raised? 'echo-area:spans "not a list of a start, an end and a face")
    (parameterize ([echo-area:spans '(oops)]) #t)))
