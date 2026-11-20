(import (tuna) (tuna plugins) (tuna eval))

;; pi starts the chats it saved as it loads, so the fake must be on the
;; PATH first.
(putenv "PATH" (string-append (getenv "HOME") "/bin:" (getenv "PATH")))
(putenv "PI_FAKE" (string-append (getenv "HOME") "/fakes"))
(putenv "PI_CODING_AGENT_DIR" (string-append (getenv "HOME") "/agent"))
(unless (file-exists? (getenv "PI_FAKE")) (mkdir (getenv "PI_FAKE")))

(import (json) (processes) (pi) (document) (haml) (web))

;; The restart test sets pi:command here, as a user's configuration does:
;; after pi has loaded and found the chats it saved.
(when (equal? (getenv "TRANSCRIPT") "restart")
  (set-option! pi:command '("pi" "--from-init")))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin minibuffer)
(use-plugin status-line)
(use-plugin files)
(use-plugin kill-ring)
(use-plugin jump-history)
(use-plugin pi-chat)
(use-plugin completion)
(use-plugin pi-picker)
(use-plugin pi-menu)

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (ref obj key) (let ([a (and (pair? obj) (assoc key obj))]) (and a (cdr a))))

(define-record-type fake
  (fields pid dir (mutable read) (mutable partial) (mutable requests) (mutable state) (mutable entries)
          (mutable leaf) (mutable answers) (mutable held)))

(define fakes (make-eqv-hashtable))

(define (folder pid) (string-append (getenv "PI_FAKE") "/" (number->string pid)))

(define (file-text path)
  (if (file-exists? path)
      (call-with-port (open-file-input-port path) (lambda (p) (let ([b (get-bytevector-all p)]) (if (eof-object? b) #vu8() b))))
      #vu8()))

;; Each session's entries, which a fake started on it again, as after a
;; restart, finds as Pi finds its session file.
(define sessions (make-hashtable string-hash string=?))

(define (new-fake pid)
  (let ([f (make-fake pid (folder pid) 0 "" '() '() '() 'null '() '())])
    (hashtable-set! fakes pid f)
    (let ([saved (and (session-id-of f) (hashtable-ref sessions (session-id-of f) #f))])
      (when saved
        (fake-entries-set! f (car saved))
        (fake-leaf-set! f (cdr saved))))
    f))

(define (fake-of chat)
  (wait-until (lambda () (let ([p (processes:pid (pi:chat-process chat))]) (and p (file-exists? (string-append (folder p) "/in"))))))
  (let ([pid (processes:pid (pi:chat-process chat))])
    (or (hashtable-ref fakes pid #f) (new-fake pid))))

(define (fake-args f) (let ([s (utf8->string (file-text (string-append (fake-dir f) "/args")))]) (split-lines s)))

(define (split-lines s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (if (< start i) (cons (substring s start i) acc) acc))]
      [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (say! f . records)
  (let ([p (open-file-output-port (string-append (fake-dir f) "/out") (file-options no-truncate no-fail append) (buffer-mode block) (native-transcoder))])
    (for-each (lambda (r) (put-string p (json->string r)) (put-string p "\n")) records)
    (close-port p)))

(define (session-id-of f)
  (let loop ([args (fake-args f)])
    (cond [(null? args) #f] [(and (string=? (car args) "--session-id") (pair? (cdr args))) (cadr args)] [else (loop (cdr args))])))

(define (state-of f)
  (append (fake-state f)
          (remp (lambda (pair) (assoc (car pair) (fake-state f))) `(("sessionId" . ,(session-id-of f)) ("sessionFile" . ,(string-append "/sessions/" (session-id-of f) ".jsonl"))
            ("isStreaming" . #f) ("isCompacting" . #f) ("thinkingLevel" . "medium")
            ("model" . (("id" . "fake-model") ("name" . "Fake Model") ("provider" . "fake") ("contextWindow" . 200000) ("reasoning" . #t)))
            ("autoCompactionEnabled" . #t) ("messageCount" . 0) ("pendingMessageCount" . 0)))))

(define (entries-after f since)
  (let loop ([es (reverse (fake-entries f))])
    (cond
      [(not since) (reverse (fake-entries f))]
      [(null? es) #f]
      [(equal? (ref (car es) "id") since) (cdr es)]
      [else (loop (cdr es))])))

(define (respond! f request data)
  (say! f `(("type" . "response") ("id" . ,(ref request "id")) ("command" . ,(ref request "type")) ("success" . #t)
            ,@(if (eq? data 'none) '() `(("data" . ,data))))))

(define (refuse! f request message)
  (say! f `(("type" . "response") ("id" . ,(ref request "id")) ("command" . ,(ref request "type")) ("success" . #f)
            ("error" . ,message))))

;; A test sets an answer for a command type: a procedure of the fake and
;; the request returning the response's data, 'none for none, or #f to
;; leave the request for the test to answer with respond! or refuse!.
(define (answer! f type proc) (fake-answers-set! f (cons (cons type proc) (fake-answers f))))

(define (default-answer f request)
  (let ([type (ref request "type")])
    (cond
      [(string=? type "get_state") (state-of f)]
      [(string=? type "get_entries")
       (let ([es (entries-after f (ref request "since"))])
         (if es
             `(("entries" . ,(list->vector es)) ("leafId" . ,(fake-leaf f)))
             'unknown))]
      [(string=? type "get_commands") '(("commands" . #()))]
      [(string=? type "get_session_stats")
       '(("tokens" . (("total" . 1234))) ("cost" . 0.41) ("contextUsage" . (("tokens" . 46000) ("contextWindow" . 200000) ("percent" . 23))))]
      [(string=? type "prompt") '(("disposition" . "started"))]
      [else 'none])))

(define (handle! f request)
  (fake-requests-set! f (append (fake-requests f) (list request)))
  (let* ([type (ref request "type")]
         [custom (assoc type (fake-answers f))]
         [data (if custom ((cdr custom) f request) (default-answer f request))])
    (cond
      [(not data) (fake-held-set! f (append (fake-held f) (list request)))]
      [(eq? data 'unknown) (refuse! f request "no such entry")]
      [else (respond! f request data)])))

(define (poll-fake! f)
  (let* ([bytes (file-text (string-append (fake-dir f) "/in"))] [n (bytevector-length bytes)])
    (when (> n (fake-read f))
      (let* ([chunk (make-bytevector (- n (fake-read f)))])
        (bytevector-copy! bytes (fake-read f) chunk 0 (bytevector-length chunk))
        (fake-read-set! f n)
        (let ([text (string-append (fake-partial f) (utf8->string chunk))])
          (let loop ([lines (split-lines text)])
            (cond
              [(null? lines) (fake-partial-set! f "")]
              [(and (null? (cdr lines)) (not (char=? (string-ref text (- (string-length text) 1)) #\newline)))
               (fake-partial-set! f (car lines))]
              [else (handle! f (string->json (car lines))) (loop (cdr lines))])))))))

(define (poll-fakes!)
  (for-each
    (lambda (name)
      (let ([pid (string->number name)])
        (when pid
          (let ([f (or (hashtable-ref fakes pid #f) (new-fake pid))])
            (poll-fake! f)))))
    (directory-list (getenv "PI_FAKE"))))

(define responder (run-with-timer 0.01 poll-fakes! 0.01))

(define asked-count (make-eqv-hashtable))
(define (asked f)
  (let* ([all (map (lambda (r) (ref r "type")) (fake-requests f))]
         [seen (hashtable-ref asked-count (fake-pid f) 0)])
    (hashtable-set! asked-count (fake-pid f) (length all))
    (list-tail all seen)))

(define (last-request f type)
  (let loop ([rs (reverse (fake-requests f))])
    (cond [(null? rs) #f] [(equal? (ref (car rs) "type") type) (car rs)] [else (loop (cdr rs))])))

(define (held f type)
  (let ([r (find (lambda (r) (equal? (ref r "type") type)) (fake-held f))])
    (when r (fake-held-set! f (remq r (fake-held f))))
    r))

(define (wait-held f type)
  (wait-until (lambda () (find (lambda (r) (equal? (ref r "type") type)) (fake-held f))))
  (held f type))

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
  `(("role" . "toolResult") ("toolCallId" . ,id) ("toolName" . ,name) ("content" . #((("type" . "text") ("text" . ,text))))
    ("isError" . ,error?) ("timestamp" . 3)))

(define (append-entry! f e)
  (fake-entries-set! f (cons e (fake-entries f)))
  (fake-leaf-set! f (ref e "id"))
  (hashtable-set! sessions (session-id-of f) (cons (fake-entries f) (fake-leaf f))))

(define (event type . fields) (cons (cons "type" type) fields))

(define (update e) (event "message_update" (cons "assistantMessageEvent" e)))

;; One turn as Pi runs it: the user's message, a reply streamed in
;; pieces, then the run settles once both are in the session.
(define (run-turn! f user-id reply-id text pieces)
  (let ([parent (if (eq? (fake-leaf f) 'null) #f (fake-leaf f))])
    (say! f (event "agent_start") (event "turn_start")
          (event "message_start" (cons "message" (user-message text)))
          (event "message_end" (cons "message" (user-message text))))
    (append-entry! f (entry user-id parent (user-message text)))
    (say! f (event "message_start" (cons "message" (assistant-message "pending")))
          (update '(("type" . "text_start") ("contentIndex" . 0))))
    (for-each (lambda (piece) (say! f (update `(("type" . "text_delta") ("contentIndex" . 0) ("delta" . ,piece))))) pieces)
    (let ([final (assistant-message "stop" (text-block (apply string-append pieces)))])
      (say! f (update `(("type" . "text_end") ("contentIndex" . 0) ("content" . ,(apply string-append pieces))))
            (event "message_end" (cons "message" final)))
      (append-entry! f (entry reply-id user-id final))
      (say! f (event "turn_end") (event "agent_end") (event "agent_settled" '("aborted" . #f))))))

(define (describe item)
  (cond
    [(pi:user-message? item) (list 'user (pi:item-key item) (pi:item-entry-id item) (pi:user-message-text item))]
    [(pi:reply? item)
     (list 'reply (pi:item-key item) (pi:item-entry-id item) (pi:reply-stop item)
           (map (lambda (p)
                  (cond
                    [(pi:text? p) (list 'text (pi:text-string p))]
                    [(pi:thinking? p) (list 'thinking (pi:thinking-string p))]
                    [else (list 'tool (pi:tool-call-name p) (pi:tool-call-state p) (pi:tool-call-output p))]))
                (pi:reply-parts item)))]
    [(pi:notice? item) (list 'notice (pi:notice-level item) (pi:notice-text item))]
    [(pi:summary? item) (list 'summary (pi:summary-kind item) (pi:summary-text item))]
    [(pi:extension-message? item) (list 'extension (pi:extension-message-type item) (pi:extension-message-text item))]
    [(pi:shell-command? item) (list 'shell (pi:shell-command-line item))]
    [else item]))

(define (transcript chat) (map describe (pi:chat-transcript chat)))

(define (raised thunk)
  (guard (c [(not (quit-condition? c))
             (list (if (pi:refused? c) 'refused 'raised)
                   (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define changes 0)
(add-hook! pi:chat-changed (lambda (chat) (set! changes (+ changes 1))))
(define activities '())
(add-hook! pi:activity-changed (lambda (chat old new) (set! activities (cons new activities))))
(define (activities!) (let ([a (reverse activities)]) (set! activities '()) a))
(define editor-texts '())
(add-hook! pi:editor-text-requested (lambda (chat text) (set! editor-texts (cons text editor-texts))))
(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (press! . keys)
  (for-each (lambda (key) (in-client (lambda () (keys:press! client key)))) keys))

(define (type! text)
  (for-each (lambda (c) (press! (case c [(#\space) "SPC"] [(#\newline) "S-RET"] [else (string c)]))) (string->list text)))

;; A command that asks or waits for Pi pauses its task, so tests run it
;; in a task of its own.
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [(not (quit-condition? c))
                 (list (if (pi:refused? c) 'refused 'raised) (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (html v) (html->string (views:draw v client)))

(define (shown chat) (text (pi-chat:buffer chat)))

(define (echo) (echo-area:current-message))

(define (flat d)
  (cond [(string? d) d] [(vector? d) ""] [else (apply string-append (map flat (cddr d)))]))

(define (short d)
  (cond
    [(string? d) d]
    [(vector? d) (list (vector-ref d 0))]
    [(memq (car d) '(markdown:paragraph markdown:heading markdown:list markdown:code-block markdown:quote markdown:table))
     (list 'md (flat d))]
    [else
     (let ([attributes (filter (lambda (a) (memq (car a) '(open state stop level method kind placement))) (cadr d))]
           [kind (let* ([name (symbol->string (car d))]
                        [name (if (and (> (string-length name) 8) (string=? (substring name 0 8) "pi-chat:")) (substring name 8 (string-length name)) name)])
                   (string->symbol (if (char=? (string-ref name 0) #\%) (substring name 1 (string-length name)) name)))])
       (cons kind (append attributes (map short (cddr d)))))]))

(define (part-datums chat kind)
  (let* ([doc (buffers:document (pi-chat:buffer chat))] [root (document:token doc 0)] [found #f])
    (document:for-each-child root 1 (- (document:length doc) 1)
      (lambda (c at)
        (when (and (not found) (document:node? c) (eq? (document:node-kind c) kind))
          (set! found (cddr (car (document:datums (document:slice doc (document:node-start c) (document:node-end c)))))))))
    (or found '())))

(define (point-in! chat kind)
  (let* ([doc (buffers:document (pi-chat:buffer chat))] [n (document:length doc)])
    (let loop ([p 0])
      (cond
        [(>= p n) (error 'point-in! "not found" kind)]
        [(let ([t (document:token doc p)]) (and (document:node? t) (eq? (document:node-kind t) kind)))
         (in-client (lambda () (views:set-point! (view) (+ p 1))))]
        [else (loop (+ p 1))]))))

(define (point-at! chat text)
  (let* ([doc (buffers:document (pi-chat:buffer chat))] [n (document:length doc)] [k (string-length text)])
    (let loop ([p 0])
      (cond
        [(>= p n) (error 'point-at! "not found" text)]
        [(and (char? (document:token doc p))
              (let ([t (document:text doc p (min n (+ p (* 3 k) 8)))])
                (and (>= (string-length t) k) (string=? (substring t 0 k) text))))
         (in-client (lambda () (views:set-point! (view) p)))]
        [else (loop (+ p 1))]))))

(define (drawn chat) (map (lambda (wrapper) (short (caddr wrapper))) (part-datums chat 'pi-chat:transcript)))

(define (opens d)
  (map (lambda (c) (cdr (assq 'open (cdr c))))
       (filter (lambda (c) (and (pair? c) (memq (car c) '(thinking tool-call summary extension-message)))) (cdr d))))

(define (drawn-dialogs chat) (map short (part-datums chat 'pi-chat:%dialogs)))

(import (console))
