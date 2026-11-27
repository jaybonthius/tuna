(import (tuna) (test) (test-runner) (hooks) (options) (processes) (pi) (test-pi) (pi-test))

(define chat (pi-test:started (getenv "HOME")))

(define first-process (pi:chat-process chat))

(test "when Pi exits, what waited for Pi is refused, and the chat says so with the end of Pi's error output"
  (let ([f (pi-test:fake chat)])
    (test-pi:hold! f "get_last_assistant_text")
    (let ([t (pi-test:in-task (lambda () (pi:last-reply chat)))])
      (test-pi:take-held! f "get_last_assistant_text")
      (test-pi:exit! f 3 "loading extensions\nFatal: out of memory\n")
      (check-equal? '(refused "Pi has ended") (pi-test:outcome t))))
  (test-runner:wait-until (lambda () (eq? (pi:chat-activity chat) 'exited)))
  (check-equal? '((notice error "Pi exited with status 3.\nloading extensions\nFatal: out of memory\n")) (pi-test:transcript chat))
  (check-equal? '(refused "Pi has ended") (pi-test:refusal (lambda () (pi:send! chat "Hi")))))

(test "restarting starts Pi again on the chat's session and swaps it in once it answers, the exit's notice gone"
  (let ([session (pi:chat-session-id chat)])
    (pi:restart! chat)
    (let ([g (pi-test:fake chat)])
      (pi-test:answered g 5)
      (check (not (eq? first-process (pi:chat-process chat))))
      (check-equal? 'idle (pi:chat-activity chat))
      (check-equal? session (list-ref (test-pi:arguments g) 3))
      (check-equal? '() (pi:chat-transcript chat)))))

(test "Pi refuses a restart while it works, since two Pis on one session would each write their own tree"
  (let ([g (pi-test:fake chat)])
    (check-equal? #f (pi:chat-working? chat))
    (test-pi:say! g (test-pi:event "agent_start"))
    (test-runner:wait-until (lambda () (eq? (pi:chat-activity chat) 'thinking)))
    (check-equal? #t (pi:chat-working? chat))
    (check-equal? '(refused "Pi is working; two Pis on one session would each write their own tree")
      (pi-test:refusal (lambda () (pi:restart! chat))))
    (test-pi:say! g (test-pi:event "agent_settled" '("aborted" . #f)))
    (pi-test:idle chat)))

(test "a restart of an idle Pi stops the old one once the new one answers"
  (let ([second-process (pi:chat-process chat)])
    (pi:restart! chat)
    (test-runner:wait-until (lambda () (processes:status second-process)))
    (check (not (eq? second-process (pi:chat-process chat))))
    (check-equal? '(-1 idle) (list (processes:status second-process) (pi:chat-activity chat)))))

(test "what the new Pi says before it answers, as its extensions set statuses and ask, reaches the chat once it is swapped in"
  (let ([speak-first
         (lambda (f)
           (test-pi:answer! f "get_state"
             (lambda (r)
               (test-pi:say! f (test-pi:ui-request "s1" "setStatus" '("statusKey" . "pool") '("statusText" . "1 pool(s)"))
                               (test-pi:ui-request "q1" "confirm" '("title" . "Trust?")))
               (test-pi:state f))))])
    (hooks:add! test-pi:fake-started speak-first)
    (pi:restart! chat)
    (hooks:remove! test-pi:fake-started speak-first)
    (test-runner:wait-until (lambda () (pair? (pi:chat-dialogs chat))))
    (check-equal? '((("pool" . "1 pool(s)")) ("Trust?"))
      (list (pi:chat-statuses chat) (map pi:dialog-title (pi:chat-dialogs chat))))))

(test "a restart whose new Pi ends before it answers is refused, and the old Pi stays"
  (let ([before (pi:chat-process chat)] [end-first (lambda (f) (test-pi:answer! f "get_state" (lambda (r) (test-pi:exit! f 1 "") #f)))])
    (hooks:add! test-pi:fake-started end-first)
    (check-equal? '(refused "Pi has ended") (pi-test:refusal (lambda () (pi:restart! chat))))
    (hooks:remove! test-pi:fake-started end-first)
    (check (eq? before (pi:chat-process chat)))
    (check-equal? 'idle (pi:chat-activity chat))))

(test "stopping ends Pi and the chat, and stopping an ended chat does nothing"
  (let ([process (pi:chat-process chat)])
    (pi:stop! chat)
    (test-runner:wait-until (lambda () (processes:status process)))
    (check-equal? '(() -1) (list (pi:chats) (processes:status process)))
    (pi:stop! chat)
    (check-equal? '() (pi:chats))))

(test "a Pi whose version cannot be read is reported, and a chat whose Pi cannot start says so, naming pi:command"
  (check-equal? '("Pi's version could not be read: cannot run no-such-pi: No such file or directory")
    (pi-test:reports-after (lambda () (options:set! pi:command '("no-such-pi"))) 1))
  (let ([lost #f])
    (check-equal? '("cannot run no-such-pi: No such file or directory")
      (pi-test:reports-after
        (lambda ()
          (set! lost (pi:start "/tmp" "lost-session"))
          (test-runner:wait-until (lambda () (eq? (pi:chat-activity lost) 'exited))))
        1))
    (check-equal? '((notice error "Pi could not start: cannot run no-such-pi: No such file or directory. pi:command is (\"no-such-pi\")."))
      (pi-test:transcript lost))
    (pi:stop! lost)))
