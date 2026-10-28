;;; A fake Pi for the pi plugin's tests (after Pilish's fake-pi contract):
;;; run as the `pi-command` option, ("gxi" ".../fake-pi.ss" ARG ...), so
;;; the chat starts it through the real helper, and production code has no
;;; test branch. It speaks Pi 1.4.0's RPC mode in strict JSONL, answers
;;; the commands the chat sends, and plays a scripted run for each prompt,
;;; chosen by the prompt's first word:
;;;   tool    a read, a bash command and an edit, with partial output;
;;;   slow    40 text chunks, 0.1 s apart (Tuna restarts meanwhile);
;;;   busy    like slow, 30 chunks: prompts sent meanwhile queue;
;;;   dialog  asks a select question and replies with the answer;
;;;   die     writes to its standard error and exits with status 3;
;;;   status  sets an extension status text and notifies;
;;;   /handled  is handled, with no run;
;;;   other   thinks, then replies "You said: PROMPT".
;;; Messages are kept in a session file (one JSON message a line) in the
;;; --fake-sessions folder, or the --session file, which a new fake Pi
;;; reads back, as Pi reopens a session.
;;;
;;;   gxi fake-pi.ss [--fake-version V] [--fake-sessions DIR] [--version]
;;;     [--mode rpc] [--session FILE] [--model M] [--thinking L] ...
(import (only-in :gerbil/runtime/hash HashTable)
        :std/encoding/json)

(def out-lock (make-mutex 'fake-pi-out))
(def state-lock (make-mutex 'fake-pi-state))

(def (emit! (record : HashTable)) => :void
  (let (line (json->string record))
    (mutex-lock! out-lock)
    (write-string line)
    (newline)
    (force-output)
    (mutex-unlock! out-lock)))

(def (now-ms) => :integer (exact (floor (* 1000 (time->seconds (current-time))))))

;;; State, under state-lock

(def messages [])          ; oldest first
(def session-file #f)
(def model "fake/fake-model")
(def thinking "low")
(def streaming? #f)
(def steering [])
(def follow-up [])
(def aborted? #f)
(def answers (make-hash-table))   ; dialog id -> response
(def agent #f)

(def (with-state (thunk : :procedure)) => :t
  (mutex-lock! state-lock)
  (try (thunk) (finally (mutex-unlock! state-lock))))

(def (save-message! (m : HashTable)) => :void
  (with-state (lambda () (set! messages (append messages [m]))))
  (when session-file
    (call-with-output-file [path: session-file append: #t create: 'maybe]
      (lambda (port) (write-string (json->string m) port) (newline port)))))

(def (load-session! (file : :string)) => :void
  (set! session-file file)
  (when (file-exists? file)
    (set! messages
      (filter values
              (map (lambda (line)
                     (with-catch (lambda (e) #f)
                                 (lambda () (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                                              (string->json line)))))
                   (call-with-input-file file (lambda (port) (read-all port read-line))))))))

(def (respond! (id :? :string) (command : :string) (data : :t) (success : :boolean := #t) (error :? :string := #f))
  => :void
  (let (record (hash ("type" "response") ("command" command) ("success" success)))
    (when id (hash-put! record "id" id))
    (when data (hash-put! record "data" data))
    (when error (hash-put! record "error" error))
    (emit! record)))

(def (queue-update!) => :void
  (emit! (hash ("type" "queue_update") ("steering" steering) ("followUp" follow-up))))

;;; Runs

(def (sleep-or-abort (seconds : :real)) => :void
  (thread-sleep! seconds)
  (when (with-state (lambda () aborted?)) (raise 'aborted)))

(def (user-message! (text : :string)) => :void
  (let (m (hash ("role" "user") ("content" text) ("timestamp" (now-ms))))
    (emit! (hash ("type" "message_start") ("message" m)))
    (emit! (hash ("type" "message_end") ("message" m)))
    (save-message! m)))

(def (assistant-start!) => :void
  (emit! (hash ("type" "message_start")
               ("message" (hash ("role" "assistant") ("content" []) ("stopReason" "pending") ("timestamp" (now-ms)))))))

(def (assistant-end! (content : :list) (reason : :string := "stop")) => :void
  (let (m (hash ("role" "assistant") ("content" content) ("stopReason" reason) ("model" "fake-model")
                ("provider" "fake") ("timestamp" (now-ms))))
    (emit! (hash ("type" "message_end") ("message" m)))
    (save-message! m)))

(def (delta! (index : :fixnum) (type : :string) (delta : :string)) => :void
  (emit! (hash ("type" "message_update")
               ("assistantMessageEvent" (hash ("type" type) ("contentIndex" index) ("delta" delta))))))

(def (part-event! (index : :fixnum) (type : :string) . fields) => :void
  (let (event (hash ("type" type) ("contentIndex" index)))
    (let lp ((fields fields))
      (when (pair? fields)
        (hash-put! event (car fields) (cadr fields))
        (lp (cddr fields))))
    (emit! (hash ("type" "message_update") ("assistantMessageEvent" event)))))

;; Stream TEXT as part INDEX of KIND ("text" or "thinking") in CHUNKS,
;; PAUSE seconds apart.
(def (stream-part! (index : :fixnum) (kind : :string) (chunks : :list) (pause : :real)) => :void
  (part-event! index (string-append kind "_start"))
  (for-each (lambda (chunk) (delta! index (string-append kind "_delta") chunk) (sleep-or-abort pause)) chunks)
  (part-event! index (string-append kind "_end") "content" (apply string-append chunks)))

(def (text-block (text : :string)) => HashTable (hash ("type" "text") ("text" text)))
(def (thinking-block (text : :string)) => HashTable (hash ("type" "thinking") ("thinking" text)))

;; A reply that thinks, then says TEXT, streamed in five-character chunks.
(def (reply! (text : :string)) => :void
  (assistant-start!)
  (stream-part! 0 "thinking" ["Let me " "think " "about it."] 0.01)
  (stream-part! 1 "text" (chunks text 5) 0.01)
  (assistant-end! [(thinking-block "Let me think about it.") (text-block text)]))

(def (chunks (text : :string) (size : :fixnum)) => :list
  (let lp ((i 0) (out []))
    (if (>= i (string-length text))
      (reverse out)
      (lp (+ i size) (cons (substring text i (min (string-length text) (+ i size))) out)))))

(def (tool-call! (index : :fixnum) (id : :string) (name : :string) (arguments : HashTable)) => :void
  (part-event! index "toolcall_start" "id" id "toolName" name)
  (part-event! index "toolcall_end" "toolCall" (hash ("type" "toolCall") ("id" id) ("name" name) ("arguments" arguments))))

(def (tool-run! (id : :string) (name : :string) (arguments : HashTable) (updates : :list) (output : :string)
                 (details : HashTable))
  => :void
  (emit! (hash ("type" "tool_execution_start") ("toolCallId" id) ("toolName" name) ("args" arguments)))
  (for-each (lambda (partial)
              (emit! (hash ("type" "tool_execution_update") ("toolCallId" id) ("toolName" name) ("args" arguments)
                           ("partialResult" (hash ("content" [(text-block partial)]) ("details" (hash))))))
              (sleep-or-abort 0.02))
            updates)
  (let (result (hash ("content" [(text-block output)]) ("details" details)))
    (emit! (hash ("type" "tool_execution_end") ("toolCallId" id) ("toolName" name) ("result" result)
                 ("isError" #f) ("durationMs" 120)))
    (let (m (hash ("role" "toolResult") ("toolCallId" id) ("toolName" name) ("content" [(text-block output)])
                  ("details" details) ("isError" #f) ("timestamp" (now-ms))))
      (emit! (hash ("type" "message_start") ("message" m)))
      (emit! (hash ("type" "message_end") ("message" m)))
      (save-message! m))))

(def (tool-scenario!) => :void
  (let ((read-args (hash ("path" "notes.txt")))
        (bash-args (hash ("command" "printf 'one\\ntwo\\n'")))
        (edit-args (hash ("path" "notes.txt") ("edits" [(hash ("oldText" "old line") ("newText" "new line"))]))))
    (assistant-start!)
    (stream-part! 0 "text" ["Looking." ] 0.01)
    (tool-call! 1 "call-read" "read" read-args)
    (tool-call! 2 "call-bash" "bash" bash-args)
    (tool-call! 3 "call-edit" "edit" edit-args)
    (assistant-end! [(text-block "Looking.")
                     (hash ("type" "toolCall") ("id" "call-read") ("name" "read") ("arguments" read-args))
                     (hash ("type" "toolCall") ("id" "call-bash") ("name" "bash") ("arguments" bash-args))
                     (hash ("type" "toolCall") ("id" "call-edit") ("name" "edit") ("arguments" edit-args))]
                    "toolUse")
    (tool-run! "call-read" "read" read-args ["first"] "first line\nsee ./notes.txt:3 here" (hash))
    (tool-run! "call-bash" "bash" bash-args ["one" "one\ntwo"] "\x1b;[1mone\x1b;[0m\ntwo\n1\n2\n3\n4\n5" (hash))
    (tool-run! "call-edit" "edit" edit-args [] "Edited notes.txt" (hash ("firstChangedLine" 2)))
    (reply-text-only! "Done.")))

(def (reply-text-only! (text : :string)) => :void
  (assistant-start!)
  (stream-part! 0 "text" (chunks text 5) 0.01)
  (assistant-end! [(text-block text)]))

(def (numbered-chunks (count : :fixnum)) => :list
  (let lp ((i 0) (out []))
    (if (= i count) (reverse out) (lp (+ i 1) (cons (string-append "chunk-" (number->string i) " ") out)))))

(def (chunked-scenario! (count : :fixnum)) => :void
  (assistant-start!)
  (let (parts (numbered-chunks count))
    (stream-part! 0 "text" parts 0.1)
    (assistant-end! [(text-block (apply string-append parts))])))

(def (dialog-scenario!) => :void
  (let (id (string-append "dialog-" (number->string (now-ms))))
    (emit! (hash ("type" "extension_ui_request") ("id" id) ("method" "select") ("title" "Pick one")
                 ("options" ["Allow" "Block"])))
    (let wait ()
      (let (answer (with-state (lambda () (hash-get answers id))))
        (if answer
          (reply-text-only!
           (string-append "Answer: "
                          (cond ((eq? (hash-ref answer "cancelled" #f) #t) "cancelled")
                                ((string? (hash-ref answer "value" #f)) (hash-ref answer "value"))
                                (else "none"))))
          (begin (sleep-or-abort 0.02) (wait)))))))

;; Run what TEXT asks, then whatever was queued meanwhile.
(def (run! (text : :string)) => :void
  (emit! (hash ("type" "agent_start")))
  (emit! (hash ("type" "turn_start")))
  (user-message! text)
  (let (aborted
        (with-catch
         (lambda (e) (if (eq? e 'aborted) #t (raise e)))
         (lambda ()
           (let (word (car (append (string-split text #\space) [""])))
             (cond
              ((equal? word "tool") (tool-scenario!))
              ((equal? word "slow") (chunked-scenario! 40))
              ((equal? word "busy") (chunked-scenario! 30))
              ((equal? word "dialog") (dialog-scenario!))
              ((equal? word "status")
               (emit! (hash ("type" "extension_ui_request") ("id" "s1") ("method" "setStatus") ("statusKey" "fake")
                            ("statusText" "\x1b;[1mbusy\x1b;[0m")))
               (emit! (hash ("type" "extension_ui_request") ("id" "n1") ("method" "notify") ("message" "Hello from an extension")))
               (reply-text-only! "Status set."))
              (else (reply! (string-append "You said: " text)))))
           #f)))
    (when aborted
      (assistant-end! [(text-block "")] "aborted"))
    (emit! (hash ("type" "turn_end")))
    (emit! (hash ("type" "agent_end") ("messages" []) ("willRetry" #f)))
    ;; Queued messages run next, unless aborted.
    (let (next (with-state (lambda ()
                             (and (not aborted)
                                  (let (queued (append steering follow-up))
                                    (and (pair? queued)
                                         (begin (set! steering []) (set! follow-up []) queued)))))))
      (if next
        (begin (queue-update!) (for-each (lambda (m) (run-inner! m)) next) (settle! #f))
        (settle! aborted)))))

(def (run-inner! (text : :string)) => :void
  (user-message! text)
  (with-catch (lambda (e) (if (eq? e 'aborted) (assistant-end! [(text-block "")] "aborted") (raise e)))
              (lambda () (reply! (string-append "You said: " text)))))

(def (settle! (aborted : :boolean)) => :void
  (with-state (lambda () (set! streaming? #f) (set! aborted? #f)))
  (emit! (hash ("type" "agent_settled") ("aborted" aborted))))

(def (agent-thread) => :void
  (let lp ()
    (let (job (thread-receive))
      (cond
       ((string? job) (run! job))
       ((procedure? job) (job)))
      (lp))))

;;; Commands

(def (command! (record : HashTable)) => :void
  (let ((type (hash-ref record "type" #f))
        (id (hash-ref record "id" #f)))
    (cond
     ((equal? type "get_state")
      (respond! id "get_state"
                (with-state
                 (lambda ()
                   (hash ("model" (hash ("id" model) ("name" model) ("provider" "fake")))
                         ("thinkingLevel" thinking) ("isStreaming" streaming?) ("isCompacting" #f)
                         ("sessionFile" session-file) ("sessionId" "fake") ("messageCount" (length messages))
                         ("pendingMessageCount" (+ (length steering) (length follow-up))))))))
     ((equal? type "get_messages") (respond! id "get_messages" (hash ("messages" (with-state (lambda () messages))))))
     ((equal? type "get_session_stats")
      (respond! id "get_session_stats"
                (hash ("cost" 0.0123) ("contextUsage" (hash ("tokens" 2300) ("contextWindow" 10000) ("percent" 23))))))
     ((equal? type "prompt")
      (let ((message (hash-ref record "message" ""))
            (behavior (hash-ref record "streamingBehavior" #f)))
        (cond
         ((string-prefix? "/handled" message) (respond! id "prompt" (hash ("disposition" "handled"))))
         ((with-state (lambda () streaming?))
          (if (string? behavior)
            (begin
              (with-state (lambda ()
                            (if (equal? behavior "steer")
                              (set! steering (append steering [message]))
                              (set! follow-up (append follow-up [message])))))
              (respond! id "prompt" (hash ("disposition" "queued")))
              (queue-update!))
            (respond! id "prompt" #f #f "Agent is already processing; specify streamingBehavior")))
         ((string-prefix? "die" message)
          (respond! id "prompt" (hash ("disposition" "started")))
          (let (err (current-error-port))
            (display "fake pi: boom, the model went away\n" err)
            (force-output err))
          (exit 3))
         (else
          (with-state (lambda () (set! streaming? #t)))
          (respond! id "prompt" (hash ("disposition" "started")))
          (thread-send agent message)))))
     ((equal? type "steer")
      (with-state (lambda () (set! steering (append steering [(hash-ref record "message" "")]))))
      (respond! id "steer" (hash ("disposition" "queued")))
      (queue-update!))
     ((equal? type "clear_queue")
      (let (cleared (with-state (lambda () (let (c (hash ("steering" steering) ("followUp" follow-up)))
                                             (set! steering []) (set! follow-up []) c))))
        (respond! id "clear_queue" cleared)
        (queue-update!)))
     ((equal? type "abort")
      (with-state (lambda () (when streaming? (set! aborted? #t))))
      (let wait () (when (with-state (lambda () streaming?)) (thread-sleep! 0.01) (wait)))
      (respond! id "abort" #f))
     ((equal? type "extension_ui_response")
      (with-state (lambda () (hash-put! answers (hash-ref record "id" "") record))))
     (else (respond! id (if (string? type) type "parse") #f #f (string-append "Unknown command: " (if (string? type) type "?")))))))

(def (main . args)
  (let lp ((args args) (version "1.4.0") (sessions #f) (session #f))
    (match args
      (["--version" . _] (displayln version) (exit 0))
      (["--fake-version" v . rest] (lp rest v sessions session))
      (["--fake-sessions" d . rest] (lp rest version d session))
      (["--session" f . rest] (lp rest version sessions f))
      (["--model" m . rest] (set! model m) (lp rest version sessions session))
      (["--thinking" t . rest] (set! thinking t) (lp rest version sessions session))
      ([_ . rest] (lp rest version sessions session))
      ([]
       (cond
        (session (load-session! session))
        (sessions (set! session-file (path-expand (string-append "fake-" (number->string (now-ms)) ".jsonl") sessions))))
       (set! agent (spawn agent-thread))
       (let read ()
         (let (line (read-line))
           (unless (eof-object? line)
             (let (record (with-catch (lambda (e) #f)
                                      (lambda () (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                                                   (string->json line)))))
               (if (hash-table? record)
                 ;; Commands run concurrently, as Pi's do.
                 (spawn (lambda () (command! record)))
                 (respond! #f "parse" #f #f "Invalid JSON")))
             (read))))
       ;; Input closed: Pi shuts down.
       (exit 0)))))
