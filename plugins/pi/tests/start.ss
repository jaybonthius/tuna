(import (tuna) (test) (test-runner) (hooks) (options) (processes) (json) (pi) (test-pi) (pi-test))

(define home (getenv "HOME"))

(test "a chat runs Pi as a user process in its folder, in Pi's mode for editors, on a session id pi chooses, its error output kept apart"
  (pi-test:activities!)
  (let* ([chat (pi:start home)] [activity (pi:chat-activity chat)] [f (pi-test:fake chat)] [args (test-pi:arguments f)])
    (check-equal? #t (pi:chat? chat))
    (check-equal? 'starting activity)
    (check-equal? '("--mode" "rpc" "--session-id") (list-head args 3))
    (check-equal? 36 (string-length (list-ref args 3)))
    (check-equal? home (test-pi:folder f))
    (check-equal? home (pi:chat-directory chat))
    (let ([p (pi:chat-process chat)])
      (check-equal? #f (processes:owner p))
      (check (bytevector? (processes:error-output p))))
    (pi-test:idle chat)
    (check-equal? '(idle) (pi-test:activities!))
    (check-equal? (list-ref args 3) (pi:chat-session-id chat))))

(test "once Pi answers, the chat has Pi's state: model, thinking level, session, compaction, use and commands, and an empty transcript"
  (let* ([chat (pi-test:started home)] [f (pi-test:fake chat)])
    (test-runner:wait-until (lambda () (= 4 (length (test-pi:requests f)))))
    (check-equal? '("get_state" "get_entries" "get_session_stats" "get_commands") (test-pi:request-types f))
    (let ([m (pi:chat-model chat)])
      (check-equal? '(#t "fake" "fake-model" "Fake Model" 200000 #t)
        (list (pi:model? m) (pi:model-provider m) (pi:model-id m) (pi:model-name m) (pi:model-context-window m)
              (pi:model-reasoning? m))))
    (check-equal? '("medium" #f #t) (list (pi:chat-thinking-level chat) (pi:chat-session-name chat) (pi:chat-auto-compaction? chat)))
    (check-equal? (string-append "/sessions/" (pi:chat-session-id chat) ".jsonl") (pi:chat-session-file chat))
    (test-runner:wait-until (lambda () (pi:chat-usage chat)))
    (let ([u (pi:chat-usage chat)])
      (check-equal? '(#t 1234 0.41 23/100 200000)
        (list (pi:usage? u) (pi:usage-tokens u) (pi:usage-cost u) (pi:usage-context-share u) (pi:usage-context-window u))))
    (check-equal? '() (pi:chat-transcript chat))))

(test "pi:chats lists the live chats oldest first, and starting on a session a live chat holds gives that chat"
  (for-each pi:stop! (pi:chats))
  (let* ([chat (pi:start home)] [other (pi:start home "fixed-session")])
    (check-equal? (list chat other) (pi:chats))
    (check (eq? other (pi:start "/elsewhere" "fixed-session")))
    (check (eq? chat (pi:start home (pi:chat-session-id chat))))
    (check-equal? '("--session-id" "fixed-session") (list-tail (test-pi:arguments (pi-test:fake other)) 2))
    (for-each pi:stop! (pi:chats))))

(test "pi:chat-changed is called when a chat starts and when it ends"
  (let* ([seen '()] [note (lambda (c) (set! seen (cons c seen)))])
    (hooks:add! pi:chat-changed note)
    (let ([chat (pi:start home)])
      (check (memq chat seen))
      (set! seen '())
      (pi:stop! chat)
      (check-equal? (list chat) seen))
    (hooks:remove! pi:chat-changed note)))

(test "a chat works in an absolute folder"
  (check-equal? '(pi:start "not an absolute path") (pi-test:violation (lambda () (pi:start "src/tuna"))))
  (check-equal? '(pi:start "not an absolute path") (pi-test:violation (lambda () (pi:start 'here)))))

(test "Pi's commands are read when Pi starts and after each settle"
  (let* ([chat (pi-test:started home)] [f (pi-test:fake chat)])
    (test-pi:answer! f "get_commands"
      (lambda (r)
        '(("commands" . #((("name" . "review") ("description" . "Review the diff") ("source" . "extension"))
                          (("name" . "fix-tests") ("description" . "Fix failing tests") ("source" . "prompt"))
                          (("name" . "skill:pdf") ("source" . "skill")))))))
    (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f)))
    (test-runner:wait-until (lambda () (= 3 (length (pi:chat-commands chat)))))
    (check-equal? '((#t "review" "Review the diff" extension) (#t "fix-tests" "Fix failing tests" prompt) (#t "skill:pdf" "" skill))
      (map (lambda (c) (list (pi:slash-command? c) (pi:slash-command-name c) (pi:slash-command-description c)
                             (pi:slash-command-source c)))
           (pi:chat-commands chat)))
    (pi:stop! chat)))

(test "the closed sets are forms that refuse a misspelling"
  (check-equal? '(idle confirm error running) (list (pi:activity idle) (pi:method confirm) (pi:stop error) (pi:tool-state running)))
  (check-raises (lambda (c) (and (syntax-violation? c) (string=? "universe of activity does not include specified symbol" (condition-message c))))
                (load-module! '(misspelled-activity))))

(define (start-refusal directory)
  (guard (c [(error? c) (condition-message c)])
    (pi:start directory)
    #f))

(test "pi refuses a Pi older than 1.5.0, asking its version whenever pi:command changes"
  (test-pi:set-version! "1.4.2")
  (check-equal? '("Pi 1.4.2 is older than 1.5.0, the version pi supports")
    (pi-test:reports-after (lambda () (options:set! pi:command '("pi" "--approve"))) 1))
  (check-equal? "Pi 1.4.2 is older than 1.5.0, the version pi supports" (start-refusal "/tmp"))
  (test-pi:set-version! "1.5.3")
  (options:set! pi:command '("pi"))
  (test-runner:wait-until (lambda () (not (start-refusal "/tmp"))))
  (for-each pi:stop! (pi:chats)))

(define (write-lines! path lines)
  (call-with-output-file path (lambda (p) (for-each (lambda (l) (put-string p l) (newline p)) lines)) 'replace))

(test "a folder's sessions are read from Pi's files, newest first: id, name, first message on one line, count and time"
  (let ([folder (string-append home "/agent/sessions/--home-groucho-src-tuna--")])
    (system (string-append "mkdir -p " folder))
    (write-lines! (string-append folder "/2026-11-01_aaa.jsonl")
      (list (json->string '(("type" . "session") ("version" . 3) ("id" . "aaa") ("cwd" . "/home/groucho/src/tuna")))
            (json->string (test-pi:entry "s" #f '(("role" . "system") ("content" . "") ("timestamp" . 0))))
            (json->string (test-pi:entry "u" "s" (test-pi:user-message "Fix the\nbuild")))
            (json->string (test-pi:entry "a" "u" (test-pi:assistant-message "stop" (test-pi:text-block "Done"))))
            (json->string '(("type" . "session_info") ("id" . "i") ("parentId" . "a") ("name" . "Build fix")))))
    (system (string-append "touch -d '2026-11-01 10:00' " folder "/2026-11-01_aaa.jsonl"))
    (write-lines! (string-append folder "/2026-11-02_bbb.jsonl")
      (list (json->string '(("type" . "session") ("version" . 3) ("id" . "bbb") ("cwd" . "/home/groucho/src/tuna")))
            (json->string (test-pi:entry "u" #f `(("role" . "user") ("content" . #((("type" . "text") ("text" . "Review")))))))))
    (system (string-append "touch -d '2026-11-02 10:00' " folder "/2026-11-02_bbb.jsonl"))
    (write-lines! (string-append folder "/notes.txt") '("not a session"))
    (let ([ss (pi:sessions "/home/groucho/src/tuna/")])
      (check-equal? '((#t "bbb" #f "Review" 1 #t) (#t "aaa" "Build fix" "Fix the build" 2 #t))
        (map (lambda (s) (list (pi:session? s) (pi:session-id s) (pi:session-name s) (pi:session-first-message s)
                               (pi:session-message-count s) (time? (pi:session-modified s))))
             ss))
      (check-equal? (string-append folder "/2026-11-02_bbb.jsonl") (pi:session-file (car ss)))
      (check (time>? (pi:session-modified (car ss)) (pi:session-modified (cadr ss)))))))

(test "a folder with no sessions has none, and pi:sessions takes only an absolute folder"
  (check-equal? '() (pi:sessions "/nowhere"))
  (check-equal? '(pi:sessions "not an absolute path") (pi-test:violation (lambda () (pi:sessions 'x))))
  (check-equal? '(pi:sessions "not an absolute path") (pi-test:violation (lambda () (pi:sessions "~/src")))))
