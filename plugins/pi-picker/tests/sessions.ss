(import (tuna) (test) (test-user) (test-runner) (options) (buffers) (views) (layout) (files) (projects) (completion)
        (completion-list) (minibuffer) (pi) (chat) (pi-chat) (pi-picker) (test-pi) (pi-picker-test pi-picking))

(define home (getenv "HOME"))

(define project (string-append home "/src/tuna"))

(system (string-append "mkdir -p " project "/lib"))

(call-with-output-file (string-append project "/.project") (lambda (p) (void)))

(options:set! projects:extra-root-markers '(".project"))

(call-with-output-file (string-append project "/lib/a.txt") (lambda (p) (put-string p "one\n")))

(define file-buffer (files:visit (string-append project "/lib/a.txt")))

(define folder
  (string-append home "/agent/sessions/--" (list->string (map (lambda (c) (if (char=? c #\/) #\- c)) (cdr (string->list project)))) "--"))

(system (string-append "mkdir -p " folder))

(define (session-header id) `(("type" . "session") ("version" . 3) ("id" . ,id) ("cwd" . ,project)))

(define aaa
  (pi-picker-test/pi-picking:write-session! folder "aaa"
    (list (session-header "aaa") (test-pi:entry "u" #f (test-pi:user-message "Fix the\nbuild"))
          (test-pi:entry "a" "u" (test-pi:assistant-message "stop" (test-pi:text-block "Done")))
          '(("type" . "session_info") ("id" . "i") ("parentId" . "a") ("name" . "Build fix")))
    "2020-01-01 10:00"))

(define bbb
  (pi-picker-test/pi-picking:write-session! folder "bbb" (list (session-header "bbb") (test-pi:entry "u" #f (test-pi:user-message "Review the parser")))
    "2020-01-02 10:00"))

(define chat (pi-picker-test/pi-picking:started (string-append project "/")))

(define f (pi-picker-test/pi-picking:fake chat))

(define (switched-to) (let ([r (test-pi:last-request f "switch_session")]) (and r (cdr (assoc "sessionPath" r)))))

(define (ends-with? s end)
  (and (>= (string-length s) (string-length end)) (string=? end (substring s (- (string-length s) (string-length end)) (string-length s)))))

(chat:show! chat)

(test "C-c C-r reads one of the chat folder's sessions, newest first, by name else first message, with age and length, and goes on in it"
  (test-user:press! "C-c C-r")
  (pi-picker-test/pi-picking:settled)
  (check-equal? '("Review the parser" "Build fix") (pi-picker-test/pi-picking:texts))
  (check-equal? '("1 message" "2 messages") (map (lambda (row) (cdr (caddr row))) (pi-picker-test/pi-picking:rows)))
  (check (ends-with? (cdr (cadr (car (pi-picker-test/pi-picking:rows)))) " d ago"))
  (test-user:type! "build")
  (pi-picker-test/pi-picking:settled)
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? aaa (switched-to)))))

(define (working!) (test-pi:set-state! f '(("isStreaming" . #t))) (test-pi:say! f (test-pi:event "agent_start")) (test-runner:wait-until (lambda () (pi:chat-working? chat))))

(define (settled!) (test-pi:set-state! f '()) (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f))) (test-runner:wait-until (lambda () (not (pi:chat-working? chat)))))

(test "while Pi works, resuming asks first"
  (working!)
  (let ([before (length (test-pi:requests f))])
    (test-user:press! "C-c C-r")
    (pi-picker-test/pi-picking:settled)
    (test-user:press! "RET")
    (check-equal? "Pi is working; stop it and resume another session? (y or n) " (pi-picker-test/pi-picking:asking))
    (test-user:press! "n")
    (check-equal? #f (member "switch_session" (list-tail (test-pi:request-types f) before)))
    (test-user:press! "C-c C-r")
    (pi-picker-test/pi-picking:settled)
    (test-user:press! "RET y")
    (test-runner:wait-until (lambda () (member "switch_session" (list-tail (test-pi:request-types f) before)))))
  (settled!))

(test "outside a chat, resuming starts a chat on the session in the buffer's project; a session a live chat is on shows that chat"
  (layout:switch-to-buffer file-buffer)
  (test-user:press! "C-c p r")
  (pi-picker-test/pi-picking:settled)
  (check-equal? '("Review the parser" "Build fix") (pi-picker-test/pi-picking:texts))
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (= 2 (length (pi:chats)))))
  (let ([resumed (chat:conversation-of (views:buffer (pi-picker-test/pi-picking:view)))])
    (check-equal? (list "bbb" (string-append project "/")) (list (pi:chat-session-id resumed) (pi:chat-directory resumed)))
    (layout:switch-to-buffer file-buffer)
    (test-user:press! "C-c p r")
    (pi-picker-test/pi-picking:settled)
    (test-user:press! "RET")
    (check-equal? 2 (length (pi:chats)))
    (check (eq? resumed (chat:conversation-of (views:buffer (pi-picker-test/pi-picking:view)))))
    (pi:stop! resumed)))

(test "/resume takes what follows it: a session's name or first message resumes it at once, other text starts the read with it"
  (chat:show! chat)
  (test-user:type! "/resume Review the parser")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? bbb (switched-to))))
  (check-equal? #f (pi-picker-test/pi-picking:session))
  (test-user:type! "/resume Rev")
  (test-user:press! "RET")
  (pi-picker-test/pi-picking:settled)
  (check-equal? '("Rev" ("Review the parser")) (list (minibuffer:input (minibuffer:current-prompt)) (pi-picker-test/pi-picking:texts)))
  (check-equal? '(quit) (pi-picker-test/pi-picking:press! "C-g")))

(test "a folder with no Pi session raises"
  (let ([empty (string-append home "/empty")])
    (mkdir empty)
    (call-with-output-file (string-append empty "/n.txt") (lambda (p) (put-string p "n\n")))
    (layout:switch-to-buffer (files:visit (string-append empty "/n.txt")))
    (check-equal? (list (string-append "no Pi session in " empty "/")) (pi-picker-test/pi-picking:press! "C-c p r"))))
