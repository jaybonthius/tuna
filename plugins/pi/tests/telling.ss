(import (tuna) (test) (test-runner) (pi) (test-pi) (pi-test))

(define chat (pi-test:started (getenv "HOME")))

(define f (pi-test:fake chat))

(define (ref object key) (let ([pair (assoc key object)]) (and pair (cdr pair))))

(define (asked-during count thunk)
  (let ([before (length (test-pi:requests f))])
    (let ([value (thunk)])
      (test-runner:wait-until (lambda () (>= (length (test-pi:requests f)) (+ before count))))
      (values (list-tail (test-pi:request-types f) before) value))))

(define (asked count thunk) (let-values ([(types value) (asked-during count thunk)]) types))

(test "every message goes as a prompt that says what to do if Pi works, and pauses the task until Pi answers"
  (test-pi:hold! f "prompt")
  (let* ([t (pi-test:in-task (lambda () (pi:send! chat "Fix it")))] [r (test-pi:take-held! f "prompt")])
    (check-equal? '("Fix it" "steer") (list (ref r "message") (ref r "streamingBehavior")))
    (check-equal? #f (pi-test:done? t))
    (test-pi:respond! f r '(("disposition" . "started")))
    (check-equal? (void) (pi-test:outcome t)))
  (let* ([t (pi-test:in-task (lambda () (pi:follow-up! chat "Then test")))] [r (test-pi:take-held! f "prompt")])
    (check-equal? '("Then test" "followUp") (list (ref r "message") (ref r "streamingBehavior")))
    (test-pi:respond! f r '(("disposition" . "started")))
    (pi-test:outcome t))
  (test-pi:answer! f "prompt" #f))

(test "a command Pi handles itself starts no run, so pi reads the session then, with no settle to wait for"
  (test-pi:answer! f "prompt" (lambda (r) '(("disposition" . "handled"))))
  (check-equal? '("prompt" "get_entries" "get_state") (asked 3 (lambda () (pi:send! chat "/review"))))
  (test-pi:answer! f "prompt" #f))

(test "Pi refuses a prompt while you compact, and the caller gets pi:&refused with Pi's message"
  (test-pi:hold! f "prompt")
  (let* ([t (pi-test:in-task (lambda () (pi:follow-up! chat "Then test")))] [r (test-pi:take-held! f "prompt")])
    (test-pi:refuse! f r "Cannot submit a prompt while compaction is in progress")
    (check-equal? '(refused "Cannot submit a prompt while compaction is in progress") (pi-test:outcome t)))
  (test-pi:answer! f "prompt" #f))

(test "Pi's queue is as it reports it; taking it back returns its texts, steers first; stopping takes it back, then stops Pi"
  (test-pi:say! f (test-pi:event "queue_update" '("steering" . #("a")) '("followUp" . #("b" "c"))))
  (test-runner:wait-until (lambda () (let-values ([(steering follow-ups) (pi:chat-queue chat)]) (pair? steering))))
  (check-equal? '(("a") ("b" "c")) (call-with-values (lambda () (pi:chat-queue chat)) list))
  (test-pi:answer! f "clear_queue" (lambda (r) '(("steering" . #("a")) ("followUp" . #("b" "c")))))
  (check-equal? '("a" "b" "c") (pi:take-queue! chat))
  (let-values ([(types texts) (asked-during 2 (lambda () (pi:abort! chat)))])
    (check-equal? '("a" "b" "c") texts)
    (check-equal? '("clear_queue" "abort") types)))

(test "after a change of session pi reads Pi's state and the whole session again"
  (check-equal? '("new_session" "get_state" "get_entries" "get_session_stats" "get_commands")
    (asked 5 (lambda () (pi:new-session! chat))))
  (check-equal? #f (ref (test-pi:last-request f "get_entries") "since"))
  (check-equal? '("switch_session" "get_state" "get_entries" "get_session_stats" "get_commands")
    (asked 5 (lambda () (pi:switch-session! chat "/s/other.jsonl"))))
  (check-equal? "/s/other.jsonl" (ref (test-pi:last-request f "switch_session") "sessionPath"))
  (test-pi:answer! f "get_fork_messages"
    (lambda (r) '(("messages" . #((("entryId" . "u1") ("text" . "Hi")) (("entryId" . "u2") ("text" . "Again")))))))
  (check-equal? '(("u1" . "Hi") ("u2" . "Again")) (pi:fork-messages chat))
  (test-pi:answer! f "fork" (lambda (r) '(("text" . "Again") ("cancelled" . #f))))
  (let-values ([(types text) (asked-during 5 (lambda () (pi:fork! chat "u2")))])
    (check-equal? "Again" text)
    (check-equal? '("fork" "get_state" "get_entries" "get_session_stats" "get_commands") types))
  (check-equal? "u2" (ref (test-pi:last-request f "fork") "entryId"))
  (check-equal? '("clone" "get_state" "get_entries" "get_session_stats" "get_commands") (asked 5 (lambda () (pi:clone! chat)))))

(test "an extension may cancel a change of session, and that is a refusal too"
  (test-pi:answer! f "clone" (lambda (r) '(("cancelled" . #t))))
  (check-equal? '(refused "an extension cancelled it") (pi-test:refusal (lambda () (pi:clone! chat)))))

(test "naming the session, compacting with instructions or none, and Pi's own compaction"
  (pi:set-session-name! chat "Refactor")
  (check-equal? '("Refactor" "Refactor") (list (ref (test-pi:last-request f "set_session_name") "name") (pi:chat-session-name chat)))
  (pi:compact! chat "Keep the API")
  (check-equal? "Keep the API" (ref (test-pi:last-request f "compact") "customInstructions"))
  (pi:compact! chat)
  (check-equal? #f (assoc "customInstructions" (test-pi:last-request f "compact")))
  (pi:set-auto-compaction! chat #f)
  (check-equal? '(#f #f) (list (ref (test-pi:last-request f "set_auto_compaction") "enabled") (pi:chat-auto-compaction? chat))))

(test "models and thinking levels are set for this chat only"
  (test-pi:answer! f "get_available_models"
    (lambda (r) '(("models" . #((("id" . "m1") ("name" . "One") ("provider" . "p") ("contextWindow" . 1000) ("reasoning" . #f))
                                (("id" . "m2") ("name" . "Two") ("provider" . "q") ("contextWindow" . 2000) ("reasoning" . #t)))))))
  (let ([ms (pi:models chat)])
    (check-equal? '("One" "Two") (map pi:model-name ms))
    (test-pi:answer! f "set_model"
      (lambda (r)
        (let ([m '(("id" . "m2") ("name" . "Two") ("provider" . "q") ("contextWindow" . 2000) ("reasoning" . #t))])
          (test-pi:set-state! f (list (cons "model" m)))
          m)))
    (pi:set-model! chat (cadr ms))
    (let ([r (test-pi:last-request f "set_model")])
      (check-equal? '("q" "m2" "Two") (list (ref r "provider") (ref r "modelId") (pi:model-name (pi:chat-model chat))))))
  (test-pi:answer! f "get_available_thinking_levels" (lambda (r) '(("levels" . #("off" "low" "high")))))
  (check-equal? '("off" "low" "high") (pi:thinking-levels chat))
  (pi:set-thinking-level! chat "low")
  (check-equal? '("low" "low") (list (ref (test-pi:last-request f "set_thinking_level") "level") (pi:chat-thinking-level chat))))

(test "exporting returns the file Pi wrote, and Pi's last reply is its text or #f"
  (test-pi:answer! f "export_html" (lambda (r) `(("path" . ,(or (ref r "outputPath") "/tmp/session.html")))))
  (check-equal? "/tmp/session.html" (pi:export-html! chat))
  (check-equal? "/tmp/x.html" (pi:export-html! chat "/tmp/x.html"))
  (test-pi:answer! f "get_last_assistant_text" (lambda (r) '(("text" . "Done."))))
  (check-equal? "Done." (pi:last-reply chat))
  (test-pi:answer! f "get_last_assistant_text" (lambda (r) '(("text" . null))))
  (check-equal? #f (pi:last-reply chat)))

(test "arguments are checked where they enter"
  (check-equal? '(pi:send! "not a string") (pi-test:violation (lambda () (pi:send! chat 'hello))))
  (check-equal? '(pi:set-model! "not a model") (pi-test:violation (lambda () (pi:set-model! chat "m2"))))
  (check-equal? '(pi:send! "not a chat") (pi-test:violation (lambda () (pi:send! 'chat "x")))))

(test "a request Pi leaves unanswered is refused when the chat stops, and every later one is refused at once"
  (test-pi:hold! f "get_last_assistant_text")
  (let ([t (pi-test:in-task (lambda () (pi:last-reply chat)))])
    (test-pi:take-held! f "get_last_assistant_text")
    (pi:stop! chat)
    (check-equal? '(refused "the chat was stopped") (pi-test:outcome t)))
  (check-equal? '() (pi:chats))
  (check-equal? '(refused "Pi has ended") (pi-test:refusal (lambda () (pi:last-reply chat)))))
