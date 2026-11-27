#!tuna
;; No import of pi, so a test that reloads pi keeps its fakes.
(import (processes) (hooks) (json) (test-runner))

(define-record-type (%fake %make-fake fake?)
  (sealed #t)
  (fields pid folder (mutable requests) (mutable answers) (mutable held) (mutable state) (mutable entries)
          (mutable leaf)))

(hooks:define-hook fake-started "Called with each fake Pi as it starts, before it takes a request.")

(define %fakes (make-eqv-hashtable))

(define %sessions (make-hashtable string-hash string=?))

(define (%home-file name) (string-append (getenv "HOME") "/" name))

(define %fakes-folder (%home-file "pi-fakes"))

;; Found from this module's source, as Tuna runs Pi by the name pi on the
;; PATH.
(define %program-folder
  (let-values ([(source object found?)
                (default-library-search-handler 'test-pi '(test-pi) (library-directories) (library-extensions))])
    (string-append (path-parent source) "/test-pi")))

(define (%ref object key)
  (let ([pair (and (pair? object) (assoc key object))]) (and pair (cdr pair))))

(define (%file-text path)
  (if (file-exists? path)
      (call-with-port (open-file-input-port path (file-options) (buffer-mode block) (native-transcoder)) get-string-all)
      ""))

(define (%lines text)
  (let loop ([i 0] [start 0] [lines '()])
    (cond
      [(= i (string-length text)) (reverse (if (< start i) (cons (substring text start i) lines) lines))]
      [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring text start i) lines))]
      [else (loop (+ i 1) start lines)])))

(define (%append! path text)
  (call-with-port (open-file-output-port path (file-options no-fail no-truncate append) (buffer-mode block)
                    (native-transcoder))
    (lambda (p) (put-string p text))))

(define (%check-fake who f)
  (unless (fake? f) (assertion-violation who "not a fake Pi" f)))

(define (arguments f)
  (%check-fake 'test-pi:arguments f)
  (%lines (%file-text (string-append (%fake-folder f) "/args"))))

(define (folder f)
  (%check-fake 'test-pi:folder f)
  (car (%lines (%file-text (string-append (%fake-folder f) "/cwd")))))

(define (%argument-session-id f)
  (let loop ([args (arguments f)])
    (cond
      [(or (null? args) (null? (cdr args))) #f]
      [(string=? (car args) "--session-id") (cadr args)]
      [else (loop (cdr args))])))

(define (%session-id f) (or (%ref (%fake-state f) "sessionId") (%argument-session-id f)))

(define (state f)
  (%check-fake 'test-pi:state f)
  (let ([id (%session-id f)])
    (append (%fake-state f)
            (remp (lambda (pair) (assoc (car pair) (%fake-state f)))
                  `(("sessionId" . ,id) ("sessionFile" . ,(string-append "/sessions/" id ".jsonl"))
                    ("isStreaming" . #f) ("isCompacting" . #f) ("thinkingLevel" . "medium")
                    ("model" . (("id" . "fake-model") ("name" . "Fake Model") ("provider" . "fake")
                                ("contextWindow" . 200000) ("reasoning" . #t)))
                    ("autoCompactionEnabled" . #t) ("messageCount" . 0) ("pendingMessageCount" . 0))))))

(define (%entries-after f since)
  (let ([all (reverse (%fake-entries f))])
    (if (not since)
        all
        (let ([tail (memp (lambda (e) (equal? (%ref e "id") since)) all)])
          (and tail (cdr tail))))))

(define (%default-answer f request)
  (let ([type (%ref request "type")])
    (cond
      [(string=? type "get_state") (state f)]
      [(string=? type "get_entries")
       (let ([entries (%entries-after f (%ref request "since"))])
         (if entries
             `(("entries" . ,(list->vector entries)) ("leafId" . ,(%fake-leaf f)))
             'unknown))]
      [(string=? type "get_commands") '(("commands" . #()))]
      [(string=? type "get_session_stats")
       '(("tokens" . (("total" . 1234))) ("cost" . 0.41)
         ("contextUsage" . (("tokens" . 46000) ("contextWindow" . 200000) ("percent" . 23))))]
      [(string=? type "prompt") '(("disposition" . "started"))]
      [else 'none])))

(define (say! f . records)
  (%check-fake 'test-pi:say! f)
  (%append! (string-append (%fake-folder f) "/out")
    (apply string-append (map (lambda (r) (string-append (json->string r) "\n")) records))))

(define (respond! f request data)
  (%check-fake 'test-pi:respond! f)
  (say! f `(("type" . "response") ("id" . ,(%ref request "id")) ("command" . ,(%ref request "type")) ("success" . #t)
            ,@(if (eq? data 'none) '() `(("data" . ,data))))))

(define (refuse! f request message)
  (%check-fake 'test-pi:refuse! f)
  (say! f `(("type" . "response") ("id" . ,(%ref request "id")) ("command" . ,(%ref request "type"))
            ("success" . #f) ("error" . ,message))))

(define (%handle! f request)
  (%fake-requests-set! f (cons request (%fake-requests f)))
  (let* ([custom (assoc (%ref request "type") (%fake-answers f))]
         [data (if custom ((cdr custom) request) (%default-answer f request))])
    (cond
      [(not data) (%fake-held-set! f (append (%fake-held f) (list request)))]
      [(eq? data 'unknown) (refuse! f request "no such entry")]
      [else (respond! f request data)])))

;; A fake announces itself only once its files exist, so the tail of its
;; file in starts at the first line Tuna sends it.
(define (%add-fake! pid)
  (let* ([f (%make-fake pid (string-append %fakes-folder "/" (number->string pid)) '() '() '() '() '() 'null)]
         [saved (hashtable-ref %sessions (%argument-session-id f) #f)])
    (when saved
      (%fake-entries-set! f (car saved))
      (%fake-leaf-set! f (cdr saved)))
    (hashtable-set! %fakes pid f)
    (fake-started f)
    (processes:start "tail" (list "-n" "+1" "-f" (string-append (%fake-folder f) "/in"))
      (processes:line-receiver 0
        (lambda (line end) (unless (eof-object? line) (%handle! f (string->json line))))))))

(define (fake process)
  (unless (processes:process? process) (assertion-violation 'test-pi:fake "not a process" process))
  (let ([found (lambda () (let ([pid (processes:pid process)]) (and pid (hashtable-ref %fakes pid #f))))])
    (test-runner:wait-until found)
    (found)))

(define (requests f)
  (%check-fake 'test-pi:requests f)
  (reverse (%fake-requests f)))

(define (request-types f) (map (lambda (r) (%ref r "type")) (requests f)))

(define (last-request f type)
  (%check-fake 'test-pi:last-request f)
  (find (lambda (r) (equal? (%ref r "type") type)) (%fake-requests f)))

(define (answer! f type answer)
  (%check-fake 'test-pi:answer! f)
  (unless (string? type) (assertion-violation 'test-pi:answer! "not a string" type))
  (unless (or (not answer) (procedure? answer)) (assertion-violation 'test-pi:answer! "not a procedure" answer))
  (let ([others (remp (lambda (pair) (string=? (car pair) type)) (%fake-answers f))])
    (%fake-answers-set! f (if answer (cons (cons type answer) others) others))))

(define (hold! f type) (answer! f type (lambda (request) #f)))

(define (take-held! f type)
  (%check-fake 'test-pi:take-held! f)
  (let ([held (lambda () (find (lambda (r) (equal? (%ref r "type") type)) (%fake-held f)))])
    (test-runner:wait-until held)
    (let ([r (held)])
      (%fake-held-set! f (remq r (%fake-held f)))
      r)))

(define (set-state! f state)
  (%check-fake 'test-pi:set-state! f)
  (%fake-state-set! f state))

(define (append-entry! f entry)
  (%check-fake 'test-pi:append-entry! f)
  (%fake-entries-set! f (cons entry (%fake-entries f)))
  (%fake-leaf-set! f (%ref entry "id"))
  (hashtable-set! %sessions (%session-id f) (cons (%fake-entries f) (%fake-leaf f))))

(define (clear-entries! f)
  (%check-fake 'test-pi:clear-entries! f)
  (%fake-entries-set! f '())
  (%fake-leaf-set! f 'null))

(define (save-session! id entries)
  (unless (string? id) (assertion-violation 'test-pi:save-session! "not a string" id))
  (hashtable-set! %sessions id (cons (reverse entries) (if (null? entries) 'null (%ref (car (last-pair entries)) "id")))))

(define (exit! f status error-text)
  (%check-fake 'test-pi:exit! f)
  (call-with-output-file (string-append (%fake-folder f) "/stderr") (lambda (p) (put-string p error-text)) 'replace)
  (%append! (string-append (%fake-folder f) "/out") (format "#exit ~a\n" status)))

(define (set-version! version)
  (unless (string? version) (assertion-violation 'test-pi:set-version! "not a string" version))
  (putenv "PI_FAKE_VERSION" version))

(define (entry id parent message)
  `(("type" . "message") ("id" . ,id) ("parentId" . ,(or parent 'null)) ("timestamp" . "2026-11-17T12:00:00.000Z")
    ("message" . ,message)))

(define (user-message text) `(("role" . "user") ("content" . ,text) ("timestamp" . 1)))

(define (text-block s) `(("type" . "text") ("text" . ,s)))

(define (thinking-block s) `(("type" . "thinking") ("thinking" . ,s)))

(define (tool-block id name arguments) `(("type" . "toolCall") ("id" . ,id) ("name" . ,name) ("arguments" . ,arguments)))

(define (assistant-message stop . blocks)
  `(("role" . "assistant") ("content" . ,(list->vector blocks)) ("stopReason" . ,stop) ("model" . "fake-model")
    ("provider" . "fake") ("timestamp" . 2)))

(define (tool-result id name text error?)
  `(("role" . "toolResult") ("toolCallId" . ,id) ("toolName" . ,name)
    ("content" . #((("type" . "text") ("text" . ,text)))) ("isError" . ,error?) ("timestamp" . 3)))

(define (event type . fields) (cons (cons "type" type) fields))

(define (update e) (event "message_update" (cons "assistantMessageEvent" e)))

(define (ui-request id method . fields)
  (append `(("type" . "extension_ui_request") ("id" . ,id) ("method" . ,method)) fields))

(define (run-turn! f user-id reply-id text pieces)
  (%check-fake 'test-pi:run-turn! f)
  (let ([parent (if (eq? (%fake-leaf f) 'null) #f (%fake-leaf f))] [whole (apply string-append pieces)])
    (say! f (event "agent_start") (event "turn_start")
          (event "message_start" (cons "message" (user-message text)))
          (event "message_end" (cons "message" (user-message text))))
    (append-entry! f (entry user-id parent (user-message text)))
    (say! f (event "message_start" (cons "message" (assistant-message "pending")))
          (update '(("type" . "text_start") ("contentIndex" . 0))))
    (for-each (lambda (piece) (say! f (update `(("type" . "text_delta") ("contentIndex" . 0) ("delta" . ,piece))))) pieces)
    (let ([final (assistant-message "stop" (text-block whole))])
      (say! f (update `(("type" . "text_end") ("contentIndex" . 0) ("content" . ,whole)))
            (event "message_end" (cons "message" final)))
      (append-entry! f (entry reply-id user-id final))
      (say! f (event "turn_end") (event "agent_end") (event "agent_settled" '("aborted" . #f))))))

(putenv "PATH" (string-append %program-folder ":" (getenv "PATH")))
(putenv "PI_FAKE" %fakes-folder)
(putenv "PI_CODING_AGENT_DIR" (%home-file "agent"))
(unless (file-exists? %fakes-folder) (mkdir %fakes-folder))
(call-with-output-file (string-append %fakes-folder "/started") (lambda (p) (void)) 'replace)

(processes:start "tail" (list "-n" "+1" "-f" (string-append %fakes-folder "/started"))
  (processes:line-receiver 0 (lambda (line end) (unless (eof-object? line) (%add-fake! (string->number line))))))
