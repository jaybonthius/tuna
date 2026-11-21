#!tuna
(import (processes) (jobs) (json))

(define-option command '("pi")
  (lambda (v) (and (list? v) (pair? v) (for-all string? v)))
  "The program and its first arguments that start Pi; pi adds --mode rpc and --session-id.")

(define-hook chat-changed "Called with a chat whenever Pi's output changes it, and when a chat starts or ends.")

(define-hook activity-changed "Called with a chat, its old activity and its new one.")

(define-hook editor-text-requested "Called with a chat and a text when an extension sets the editor's text.")

(define-enumeration activity (starting idle thinking replying running compacting retrying exited) %activities)

(define-enumeration method (select confirm input editor) %methods)

(define-enumeration stop (pending stop length tool-use error aborted deferred) %stops)

(define-enumeration tool-state (called running done failed) %tool-states)

(define-condition-type &refused &error %make-refused refused?)

;; Questions, statuses, widgets and the queue are saved because Pi says
;; each once, and the log that a reload replays keeps only the latest
;; output.
(define-saved %chats '() (lambda (v) (and (list? v) (for-all vector? v))))

(define-record-type (%item %make-item %item?)
  (fields (immutable key item-key) (immutable entry-id item-entry-id)))

(define-record-type (%user-message %make-user-message user-message?)
  (parent %item) (sealed #t)
  (fields (immutable text user-message-text) (immutable images user-message-images)))

(define-record-type (%reply %make-reply reply?)
  (parent %item) (sealed #t)
  (fields (immutable parts reply-parts) (immutable stop reply-stop) (immutable error reply-error)
          (immutable model reply-model)))

(define-record-type (%shell-command %make-shell-command shell-command?)
  (parent %item) (sealed #t)
  (fields (immutable line shell-command-line) (immutable output shell-command-output)
          (immutable exit shell-command-exit)))

(define-record-type (%summary %make-summary summary?)
  (parent %item) (sealed #t)
  (fields (immutable kind summary-kind) (immutable text summary-text)
          (immutable tokens-before summary-tokens-before)))

(define-record-type (%extension-message %make-extension-message extension-message?)
  (parent %item) (sealed #t)
  (fields (immutable type extension-message-type) (immutable text extension-message-text)))

(define-record-type (%notice %make-notice notice?)
  (parent %item) (sealed #t)
  (fields (immutable level notice-level) (immutable text notice-text)))

(define-record-type (%text %make-text text?)
  (sealed #t)
  (fields (immutable string text-string)))

(define-record-type (%thinking %make-thinking thinking?)
  (sealed #t)
  (fields (immutable string thinking-string)))

(define-record-type (%tool-call %make-tool-call tool-call?)
  (sealed #t)
  (fields (immutable id tool-call-id) (immutable name tool-call-name) (immutable arguments tool-call-arguments)
          (immutable state tool-call-state) (immutable output tool-call-output)
          (immutable images tool-call-images) (immutable duration tool-call-duration)))

(define-record-type (%widget %make-widget widget?)
  (sealed #t)
  (fields (immutable key widget-key) (immutable placement widget-placement) (immutable lines widget-lines)))

(define-record-type (%model %make-model model?)
  (sealed #t)
  (fields (immutable provider model-provider) (immutable id model-id) (immutable name model-name)
          (immutable context-window model-context-window) (immutable reasoning? model-reasoning?)))

(define-record-type (%usage %make-usage usage?)
  (sealed #t)
  (fields (immutable tokens usage-tokens) (immutable cost usage-cost)
          (immutable context-share usage-context-share) (immutable context-window usage-context-window)))

(define-record-type (%slash-command %make-slash-command slash-command?)
  (sealed #t)
  (fields (immutable name slash-command-name) (immutable description slash-command-description)
          (immutable source slash-command-source)))

(define-record-type (%session %make-session session?)
  (sealed #t)
  (fields (immutable id session-id) (immutable file session-file) (immutable name session-name)
          (immutable first-message session-first-message) (immutable message-count session-message-count)
          (immutable modified session-modified)))

(define-record-type (%dialog %make-dialog dialog?)
  (sealed #t)
  (fields (immutable id dialog-id) (immutable method dialog-method) (immutable title dialog-title)
          (immutable message dialog-message) (immutable options dialog-options) (immutable text dialog-text)
          (immutable arrived %dialog-arrived) (immutable timeout %dialog-timeout)))

;; Pi's output is split into lines and parsed off the main thread, since
;; one answer holds a whole session, which reaches a hundred megabytes.
;; Lines are split on LF only, as Pi's framing requires: U+2028 may
;; appear inside a string.
(jobs:define-worker (%parser input emit receive)
  (import (json))
  (define (line-of parts)
    (let* ([n (fold-left (lambda (n p) (fx+ n (bytevector-length p))) 0 parts)]
           [joined (make-bytevector n)])
      (fold-left (lambda (at p) (bytevector-copy! p 0 joined at (bytevector-length p)) (fx+ at (bytevector-length p)))
                 0 parts)
      (if (and (fx> n 0) (fx= (bytevector-u8-ref joined (fx- n 1)) 13))
          (let ([trimmed (make-bytevector (fx- n 1))])
            (bytevector-copy! joined 0 trimmed 0 (fx- n 1))
            trimmed)
          joined)))
  (define (part bytes start end)
    (let ([p (make-bytevector (fx- end start))])
      (bytevector-copy! bytes start p 0 (fx- end start))
      p))
  (define (emit-line! bytes end)
    (emit (cons end (guard (c [(json-error? c) #f]) (bytevector->json bytes)))))
  (let loop ([held '()] [first? #t] [skipping? #f])
    (let ([chunk (receive)])
      (if (eq? chunk 'end)
          (emit 'end)
          (let* ([bytes (car chunk)] [end (cdr chunk)] [n (bytevector-length bytes)] [start (- end n)]
                 [skipping? (if first? (> start 0) skipping?)])
            (let scan ([i 0] [j 0] [held held] [skipping? skipping?])
              (cond
                [(fx= j n)
                 (loop (if (or skipping? (fx= i n)) held (cons (part bytes i n) held)) #f skipping?)]
                [(fx= (bytevector-u8-ref bytes j) 10)
                 (unless skipping?
                   (let ([line (line-of (reverse (cons (part bytes i j) held)))])
                     (unless (fx= (bytevector-length line) 0)
                       (emit-line! line (+ start j 1)))))
                 (scan (fx+ j 1) (fx+ j 1) '() #f)]
                [else (scan i (fx+ j 1) held skipping?)])))))))

;; Only the lines that name a session or hold a message are parsed, so a
;; long session is read without building its entries.
(jobs:define-worker (%session-lister folder emit)
  (import (json))
  (define (prefix? s p)
    (and (fx>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))
  (define (contains? s p)
    (let ([n (string-length s)] [m (string-length p)])
      (let loop ([i 0])
        (and (fx<= (fx+ i m) n) (or (string=? (substring s i (fx+ i m)) p) (loop (fx+ i 1)))))))
  (define (ref obj key) (let ([a (and (list? obj) (assoc key obj))]) (and a (not (eq? (cdr a) 'null)) (cdr a))))
  (define (one-line s)
    (list->string (map (lambda (c) (if (memv c '(#\newline #\return #\tab)) #\space c)) (string->list s))))
  (define (message-text m)
    (let ([c (ref m "content")])
      (cond
        [(string? c) c]
        [(vector? c)
         (apply string-append
           (map (lambda (b) (if (equal? (ref b "type") "text") (or (ref b "text") "") "")) (vector->list c)))]
        [else ""])))
  (define (read-session path)
    (call-with-port (open-file-input-port path (file-options) (buffer-mode block) (native-transcoder))
      (lambda (port)
        (let loop ([id #f] [name #f] [first #f] [count 0])
          (let ([line (get-line port)])
            (if (eof-object? line)
                (and id (vector id path name (or first "") count
                                (let ([t (file-modification-time path)]) (cons (time-second t) (time-nanosecond t)))))
                (cond
                  [(prefix? line "{\"type\":\"session\",")
                   (loop (ref (guard (c [(json-error? c) '()]) (string->json line)) "id") name first count)]
                  [(prefix? line "{\"type\":\"session_info\"")
                   (loop id (ref (guard (c [(json-error? c) '()]) (string->json line)) "name") first count)]
                  [(and (prefix? line "{\"type\":\"message\"")
                        (or (contains? line "\"role\":\"user\"") (contains? line "\"role\":\"assistant\"")))
                   (let ([first (or first
                                    (and (contains? line "\"role\":\"user\"")
                                         (let ([m (ref (guard (c [(json-error? c) '()]) (string->json line)) "message")])
                                           (and (equal? (ref m "role") "user") (one-line (message-text m))))))])
                     (loop id name first (fx+ count 1)))]
                  [else (loop id name first count)])))))))
  (emit
    (if (file-directory? folder)
        (fold-left
          (lambda (acc file)
            (let ([path (string-append folder "/" file)])
              (if (and (fx> (string-length file) 6)
                       (string=? (substring file (fx- (string-length file) 6) (string-length file)) ".jsonl"))
                  (let ([s (guard (c [(i/o-error? c) #f]) (read-session path))])
                    (if s (cons s acc) acc))
                  acc)))
          '()
          (directory-list folder))
        '())))

(module %internals
  (make-chat chat-record? %chat-directory %chat-link %chat-link-set! %chat-activity %chat-activity-set!
   %chat-session-id %chat-session-id-set! %chat-session-file %chat-session-file-set! %chat-session-name %chat-session-name-set!
   %chat-model %chat-model-set! %chat-thinking-level %chat-thinking-level-set! %chat-auto-compaction? %chat-auto-compaction?-set!
   %chat-usage %chat-usage-set! %chat-commands %chat-commands-set! %chat-dialogs %chat-dialogs-set! %chat-statuses %chat-statuses-set!
   %chat-widgets %chat-widgets-set! %chat-steering %chat-steering-set! %chat-follow-ups %chat-follow-ups-set!
   %chat-answered %chat-answered-set! %chat-transcript-cache %chat-transcript-cache-set!
   make-link link-process link-job link-job-set! link-pending link-replaying? link-replaying?-set!
   link-ended? link-ended?-set! link-status link-status-set! link-parsed-end? link-parsed-end?-set!
   link-seen link-seen-set! link-end-sent? link-end-sent?-set! link-held link-held-set!
   %chat-entries %chat-entries-set! %chat-leaf %chat-leaf-set! %chat-cursor %chat-cursor-set! %chat-items %chat-items-set!
   %chat-results %chat-results-set! %chat-live %chat-live-set! %chat-tools %chat-notices %chat-notices-set!
   %chat-running? %chat-running?-set!
   %chat-refreshing %chat-refreshing-set! %chat-timers %chat-timers-set!
   make-live live-role live-key live-key-set! live-parts live-parts-set! live-message live-message-set!
   live-ended? live-ended?-set!
   make-live-part live-part-type live-part-pieces live-part-id live-part-name live-part-arguments
   make-tool %tool-name %tool-arguments %tool-arguments-set! %tool-state %tool-state-set! %tool-output %tool-output-set!
   %tool-images %tool-images-set! %tool-duration %tool-duration-set!
   ref text-of now-ms ms->time make-session-id next-request-id)

  (define-record-type (chat-record make-chat chat-record?)
    (sealed #t)
    (fields (immutable directory %chat-directory)
            (mutable link %chat-link %chat-link-set!)
            (mutable activity %chat-activity %chat-activity-set!)
            (mutable session-id %chat-session-id %chat-session-id-set!)
            (mutable session-file %chat-session-file %chat-session-file-set!)
            (mutable session-name %chat-session-name %chat-session-name-set!)
            (mutable model %chat-model %chat-model-set!)
            (mutable thinking-level %chat-thinking-level %chat-thinking-level-set!)
            (mutable auto-compaction? %chat-auto-compaction? %chat-auto-compaction?-set!)
            (mutable usage %chat-usage %chat-usage-set!)
            (mutable commands %chat-commands %chat-commands-set!)
            (mutable dialogs %chat-dialogs %chat-dialogs-set!)
            (mutable statuses %chat-statuses %chat-statuses-set!)
            (mutable widgets %chat-widgets %chat-widgets-set!)
            (mutable steering %chat-steering %chat-steering-set!)
            (mutable follow-ups %chat-follow-ups %chat-follow-ups-set!)
            (mutable answered %chat-answered %chat-answered-set!)
            (mutable transcript-cache %chat-transcript-cache %chat-transcript-cache-set!)
            (mutable entries %chat-entries %chat-entries-set!)
            (mutable leaf %chat-leaf %chat-leaf-set!)
            (mutable cursor %chat-cursor %chat-cursor-set!)
            (mutable items %chat-items %chat-items-set!)
            (mutable results %chat-results %chat-results-set!)
            (mutable live %chat-live %chat-live-set!)
            (immutable tools %chat-tools)
            (mutable notices %chat-notices %chat-notices-set!)
            (mutable running? %chat-running? %chat-running?-set!)
            (mutable refreshing %chat-refreshing %chat-refreshing-set!)
            (mutable timers %chat-timers %chat-timers-set!))
    (protocol
      (lambda (new)
        (lambda (directory session-id)
          (new directory #f (activity starting) session-id #f #f #f #f #f #f '() '() '() '() '() '() '() #f
               (make-hashtable string-hash string=?) #f #f '#() (make-hashtable string-hash string=?) '()
               (make-hashtable string-hash string=?) '() #f '() '())))))

  ;; Apart from the chat, since a restart follows a second process until
  ;; its Pi answers.
  (define-record-type (link make-link link?)
    (sealed #t)
    (fields (immutable process link-process)
            (mutable job link-job link-job-set!)
            (immutable pending link-pending)
            (mutable replaying? link-replaying? link-replaying?-set!)
            (mutable ended? link-ended? link-ended?-set!)
            (mutable status link-status link-status-set!)
            (mutable parsed-end? link-parsed-end? link-parsed-end?-set!)
            (mutable seen link-seen link-seen-set!)
            (mutable end-sent? link-end-sent? link-end-sent?-set!)
            (mutable held link-held link-held-set!))
    (protocol
      (lambda (new)
        (lambda (process replaying?)
          (new process #f (make-hashtable string-hash string=?) replaying? #f #f #f '() #f '())))))

  ;; Pi announces no entry id, so a message is live until the entries
  ;; read after it hold it.
  (define-record-type (live make-live live?)
    (sealed #t)
    (fields (immutable role live-role)
            (mutable key live-key live-key-set!)
            (mutable parts live-parts live-parts-set!)
            (mutable message live-message live-message-set!)
            (mutable ended? live-ended? live-ended?-set!)))

  ;; A part's pieces are kept newest first and joined when the transcript
  ;; is read, since joining them at each piece would copy the reply each
  ;; time.
  (define-record-type (live-part make-live-part live-part?)
    (sealed #t)
    (fields (immutable type live-part-type) (immutable pieces live-part-pieces)
            (immutable id live-part-id) (immutable name live-part-name) (immutable arguments live-part-arguments)))

  (define-record-type (tool make-tool tool?)
    (sealed #t)
    (fields (immutable name %tool-name)
            (mutable arguments %tool-arguments %tool-arguments-set!)
            (mutable state %tool-state %tool-state-set!)
            (mutable output %tool-output %tool-output-set!)
            (mutable images %tool-images %tool-images-set!)
            (mutable duration %tool-duration %tool-duration-set!)))

  (define (ref obj key)
    (let ([a (and (pair? obj) (assoc key obj))])
      (and a (not (eq? (cdr a) 'null)) (cdr a))))

  (define (text-of content)
    (cond
      [(string? content) content]
      [(vector? content)
       (let loop ([blocks (vector->list content)] [acc '()])
         (cond
           [(null? blocks) (apply string-append (reverse acc))]
           [(equal? (ref (car blocks) "type") "text")
            (loop (cdr blocks) (cons (or (ref (car blocks) "text") "") (if (null? acc) acc (cons "\n" acc))))]
           [else (loop (cdr blocks) acc)]))]
      [else ""]))

  (define (now-ms)
    (let ([t (current-time 'time-utc)])
      (+ (* (time-second t) 1000) (quotient (time-nanosecond t) 1000000))))

  (define (ms->time ms)
    (make-time 'time-utc (* (remainder ms 1000) 1000000) (quotient ms 1000)))

  (define (random-bytes n)
    (call-with-port (open-file-input-port "/dev/urandom")
      (lambda (p) (get-bytevector-n p n))))

  (define (hex bytes from to)
    (let loop ([i from] [acc '()])
      (if (fx= i to)
          (apply string-append (reverse acc))
          (let ([s (string-downcase (number->string (bytevector-u8-ref bytes i) 16))])
            (loop (fx+ i 1) (cons (if (fx= (string-length s) 1) (string-append "0" s) s) acc))))))

  (define (random-hex n) (hex (random-bytes n) 0 n))

  (define (make-session-id)
    (let ([b (random-bytes 16)])
      (bytevector-u8-set! b 6 (fxior #x40 (fxand (bytevector-u8-ref b 6) #x0f)))
      (bytevector-u8-set! b 8 (fxior #x80 (fxand (bytevector-u8-ref b 8) #x3f)))
      (string-append (hex b 0 4) "-" (hex b 4 6) "-" (hex b 6 8) "-" (hex b 8 10) "-" (hex b 10 16))))

  ;; Unique to this load, so a response replayed from the log, written
  ;; for a request of an earlier load, never matches a new request.
  (define request-prefix (random-hex 6))

  (define request-count 0)

  (define (next-request-id)
    (set! request-count (+ request-count 1))
    (string-append request-prefix "-" (number->string request-count))))

(import %internals)

(define %live-chats '())

(define %minimum-version '(1 5 0))

(define %version-refusal #f)

(define (%check-chat who v)
  (unless (chat-record? v)
    (assertion-violation who "not a chat" v)))

(define (%check-directory who v)
  (unless (and (string? v) (fx> (string-length v) 0) (char=? (string-ref v 0) #\/))
    (assertion-violation who "not an absolute path" v)))

(define (%check-dialog who v)
  (unless (dialog? v)
    (assertion-violation who "not a question" v)))

(define (%refuse who message . irritants)
  (raise (condition (%make-refused) (make-who-condition who) (make-message-condition message)
                    (make-irritants-condition irritants))))

(define (%version-numbers text)
  (let loop ([cs (string->list text)] [digits '()] [numbers '()])
    (cond
      [(and (pair? cs) (char-numeric? (car cs))) (loop (cdr cs) (cons (car cs) digits) numbers)]
      [(and (pair? cs) (char=? (car cs) #\.) (pair? digits))
       (loop (cdr cs) '() (cons (string->number (list->string (reverse digits))) numbers))]
      [(pair? digits) (reverse (cons (string->number (list->string (reverse digits))) numbers))]
      [(and (pair? cs) (null? numbers)) (loop (cdr cs) '() '())]
      [else (reverse numbers)])))

(define (%older? version minimum)
  (cond
    [(null? minimum) #f]
    [(null? version) #t]
    [(< (car version) (car minimum)) #t]
    [(> (car version) (car minimum)) #f]
    [else (%older? (cdr version) (cdr minimum))]))

(define (%check-version!)
  (let ([cmd (command)])
    (guard (c [(not (quit-condition? c))
               (set! %version-refusal #f)
               (report (condition (make-warning)
                         (make-message-condition
                           (string-append "Pi's version could not be read: "
                                          (if (message-condition? c) (condition-message c) "it did not run")))))])
      (let-values ([(status out err) (processes:run (car cmd) (append (cdr cmd) '("--version")) #f
                                                  (processes:options [separate-stderr #t]))])
        (let ([version (%version-numbers (utf8->string out))])
          (cond
            [(and (pair? version) (%older? version %minimum-version))
             (set! %version-refusal
               (string-append "Pi " (%trim (utf8->string out)) " is older than 1.5.0, the version pi supports"))
             (report (condition (make-warning) (make-message-condition %version-refusal)))]
            [else (set! %version-refusal #f)]))))))

(define (%trim s)
  (let loop ([n (string-length s)])
    (if (and (fx> n 0) (char-whitespace? (string-ref s (fx- n 1)))) (loop (fx- n 1)) (substring s 0 n))))

(define (%dialog->saved d)
  (vector (dialog-id d) (dialog-method d) (dialog-title d) (dialog-message d) (dialog-options d) (dialog-text d)
          (%dialog-arrived d) (%dialog-timeout d)))

(define (%saved->dialog v)
  (%make-dialog (vector-ref v 0) (vector-ref v 1) (vector-ref v 2) (vector-ref v 3) (vector-ref v 4)
                (vector-ref v 5) (vector-ref v 6) (vector-ref v 7)))

(define (%chat->saved chat)
  (let ([link (%chat-link chat)])
    (vector (and link (processes:id (link-process link)))
            (%chat-session-id chat)
            (%chat-directory chat)
            (map %dialog->saved (%chat-dialogs chat))
            (%chat-statuses chat)
            (map (lambda (w) (vector (widget-key w) (widget-placement w) (widget-lines w))) (%chat-widgets chat))
            (%chat-steering chat)
            (%chat-follow-ups chat)
            (%chat-answered chat))))

(define (%save!)
  (set-saved! %chats (map %chat->saved %live-chats)))

(define (%changed! chat)
  (%chat-transcript-cache-set! chat #f)
  (chat-changed chat))

(define (%set-activity! chat new)
  (let ([old (%chat-activity chat)])
    (unless (eq? old new)
      (%chat-activity-set! chat new)
      (activity-changed chat old new))))

(define (%send-json! link obj)
  (processes:send! (link-process link) (string-append (json->string obj) "\n")))

(define (%request! link obj on-answer on-fail)
  (if (link-ended? link)
      (on-fail "Pi has ended")
      (let ([id (next-request-id)])
        (hashtable-set! (link-pending link) id (cons on-answer on-fail))
        (%send-json! link (cons (cons "id" id) obj)))))

(define (%response-failure response)
  (cond
    [(not (eq? (ref response "success") #t)) (or (ref response "error") "Pi refused")]
    [(let ([data (ref response "data")]) (and (pair? data) (eq? (ref data "cancelled") #t)))
     "an extension cancelled it"]
    [else #f]))

(define (%call chat who obj)
  (let ([link (%chat-link chat)])
    (unless link
      (%refuse who "the chat has no Pi"))
    (suspend
      (lambda (resume)
        (as-module (this-module)
          (%request! link obj
            (lambda (data) (resume (lambda () data)))
            (lambda (message)
              (let ([c (condition (%make-refused) (make-who-condition who) (make-message-condition message))])
                (resume (lambda () (raise c)))))))))))

(define (%fail-pending! link message)
  (let-values ([(ids handlers) (hashtable-entries (link-pending link))])
    (hashtable-clear! (link-pending link))
    (vector-for-each (lambda (h) ((cdr h) message)) handlers)))

;; A burst of events asks Pi once: a refresh asked for while one is out
;; runs again after its answer.

(define %refresh!
  (case-lambda
    [(chat kind make-request on-answer) (%refresh! chat kind make-request on-answer (lambda () #f))]
    [(chat kind make-request on-answer again-on-failure?)
     (let ([state (assq kind (%chat-refreshing chat))] [link (%chat-link chat)])
       (cond
         [(not link) (void)]
         [state (set-cdr! state #t)]
         [else
          (%chat-refreshing-set! chat (cons (cons kind #f) (%chat-refreshing chat)))
          (let ([done (lambda (again?)
                        (let ([again? (or again? (cdr (assq kind (%chat-refreshing chat))))])
                          (%chat-refreshing-set! chat (remp (lambda (s) (eq? (car s) kind)) (%chat-refreshing chat)))
                          (when (and again? (not (link-ended? link)))
                            (%refresh! chat kind make-request on-answer again-on-failure?))))])
            (%request! link (make-request)
              (lambda (data) (on-answer data) (done #f))
              (lambda (message) (done (again-on-failure?)))))]))]))

(define (%refresh-state! chat)
  (%refresh! chat 'state (lambda () '(("type" . "get_state")))
    (lambda (data) (%apply-state! chat data))))

(define (%refresh-stats! chat)
  (%refresh! chat 'stats (lambda () '(("type" . "get_session_stats")))
    (lambda (data)
      (%chat-usage-set! chat (%usage-of data))
      (%changed! chat))))

(define (%refresh-commands! chat)
  (%refresh! chat 'commands (lambda () '(("type" . "get_commands")))
    (lambda (data)
      (%chat-commands-set! chat
        (let ([commands (ref data "commands")])
          (if (vector? commands) (map %slash-command-of (vector->list commands)) '())))
      (%changed! chat))))

;; Pi refuses a cursor that names no entry, as after a change of session
;; an extension made; the whole session is read instead.
(define (%refresh-entries! chat)
  (%refresh! chat 'entries
    (lambda ()
      (if (%chat-cursor chat)
          (list '("type" . "get_entries") (cons "since" (%chat-cursor chat)))
          '(("type" . "get_entries"))))
    (lambda (data) (%apply-entries! chat data))
    (lambda ()
      (and (%chat-cursor chat)
           (begin
             (%chat-cursor-set! chat #f)
             (hashtable-clear! (%chat-entries chat))
             #t)))))

;; After a change of session the old cursor names no entry.
(define (%reload-entries! chat)
  (%chat-cursor-set! chat #f)
  (hashtable-clear! (%chat-entries chat))
  (%refresh-entries! chat))

(define (%refresh-all! chat)
  (%refresh-state! chat)
  (%reload-entries! chat)
  (%refresh-stats! chat)
  (%refresh-commands! chat))

(define (%model-of m)
  (and (pair? m)
       (%make-model (or (ref m "provider") "") (or (ref m "id") "") (or (ref m "name") (ref m "id") "")
                    (ref m "contextWindow") (eq? (ref m "reasoning") #t))))

(define (%usage-of data)
  (let ([tokens (ref data "tokens")] [context (ref data "contextUsage")])
    (%make-usage (or (and (pair? tokens) (ref tokens "total")) 0)
                 (or (ref data "cost") 0)
                 (let ([percent (and (pair? context) (ref context "percent"))])
                   (and (number? percent) (/ percent 100)))
                 (and (pair? context) (ref context "contextWindow")))))

(define (%slash-command-of c)
  (%make-slash-command (or (ref c "name") "") (or (ref c "description") "")
                       (let ([s (ref c "source")])
                         (cond
                           [(equal? s "prompt") 'prompt]
                           [(equal? s "skill") 'skill]
                           [else 'extension]))))

(define (%apply-state! chat data)
  (let ([session-id (ref data "sessionId")])
    (%chat-model-set! chat (%model-of (ref data "model")))
    (%chat-thinking-level-set! chat (ref data "thinkingLevel"))
    (%chat-session-file-set! chat (ref data "sessionFile"))
    (%chat-session-name-set! chat (ref data "sessionName"))
    (%chat-auto-compaction?-set! chat (eq? (ref data "autoCompactionEnabled") #t))
    (when (and session-id (not (equal? session-id (%chat-session-id chat))))
      (%chat-session-id-set! chat session-id)
      (%save!)
      (%after-session-change! chat))
    (cond
      [(eq? (ref data "isCompacting") #t) (%set-activity! chat (activity compacting))]
      [(eq? (ref data "isStreaming") #t)
       (when (memq (%chat-activity chat) (list (activity starting) (activity idle)))
         (%set-activity! chat (activity thinking)))]
      [else
       (%chat-running?-set! chat #f)
       (%set-activity! chat (activity idle))])
    (%changed! chat)))

(define (%entry-items chat)
  (let* ([entries (%chat-entries chat)] [leaf (%chat-leaf chat)]
         [branch (let walk ([id leaf] [acc '()])
                   (let ([e (and id (hashtable-ref entries id #f))])
                     (if e (walk (ref e "parentId") (cons e acc)) acc)))]
         [results (make-hashtable string-hash string=?)])
    (for-each
      (lambda (e)
        (let ([m (ref e "message")])
          (when (and (equal? (ref e "type") "message") (equal? (ref m "role") "toolResult") (ref m "toolCallId"))
            (hashtable-set! results (ref m "toolCallId") m))))
      branch)
    (%chat-results-set! chat results)
    (let loop ([es branch] [k 0] [acc '()])
      (if (null? es)
          (list->vector (reverse acc))
          (let ([item (%entry->item chat (car es) k)])
            (if item
                (loop (cdr es) (fx+ k 1) (cons item acc))
                (loop (cdr es) k acc)))))))

(define (%entry->item chat e k)
  (let ([type (ref e "type")] [id (ref e "id")])
    (cond
      [(equal? type "message") (%message->item chat (ref e "message") k id)]
      [(equal? type "custom_message")
       (and (eq? (ref e "display") #t)
            (%make-extension-message k id (or (ref e "customType") "") (text-of (ref e "content"))))]
      [(equal? type "compaction")
       (%make-summary k id 'compaction (or (ref e "summary") "") (ref e "tokensBefore"))]
      [(equal? type "branch_summary") (%make-summary k id 'branch (or (ref e "summary") "") #f)]
      [else #f])))

(define (%message->item chat m k id)
  (let ([role (ref m "role")])
    (cond
      [(equal? role "user") (%user-item m k id)]
      [(equal? role "assistant")
       (%make-reply k id (%reply-parts chat (ref m "content")) (%stop-of (ref m "stopReason")) (ref m "errorMessage")
                    (ref m "model"))]
      [(equal? role "bashExecution")
       (%make-shell-command k id (or (ref m "command") "") (or (ref m "output") "") (ref m "exitCode"))]
      [(equal? role "custom")
       (and (eq? (ref m "display") #t)
            (%make-extension-message k id (or (ref m "customType") "") (text-of (ref m "content"))))]
      [(equal? role "compactionSummary") (%make-summary k id 'compaction (or (ref m "summary") "") (ref m "tokensBefore"))]
      [(equal? role "branchSummary") (%make-summary k id 'branch (or (ref m "summary") "") #f)]
      [else #f])))

(define (%user-item m k id)
  (let ([content (ref m "content")])
    (%make-user-message k id (text-of content)
      (if (vector? content)
          (fold-left (lambda (n b) (if (equal? (ref b "type") "image") (fx+ n 1) n)) 0 (vector->list content))
          0))))

(define (%stop-of s)
  (cond
    [(equal? s "stop") (stop stop)]
    [(equal? s "length") (stop length)]
    [(equal? s "toolUse") (stop tool-use)]
    [(equal? s "error") (stop error)]
    [(equal? s "aborted") (stop aborted)]
    [(equal? s "deferred") (stop deferred)]
    [else (stop pending)]))

(define (%images-in content)
  (if (vector? content)
      (fold-left (lambda (n b) (if (equal? (ref b "type") "image") (fx+ n 1) n)) 0 (vector->list content))
      0))

(define (%tool-call-of chat block)
  (let* ([id (or (ref block "id") "")] [name (or (ref block "name") "")]
         [arguments (or (ref block "arguments") '())]
         [result (hashtable-ref (%chat-results chat) id #f)]
         [t (hashtable-ref (%chat-tools chat) id #f)])
    (cond
      [result
       (%make-tool-call id name arguments (if (eq? (ref result "isError") #t) (tool-state failed) (tool-state done))
                        (text-of (ref result "content")) (%images-in (ref result "content")) (and t (%tool-duration t)))]
      [t (%make-tool-call id name (if (null? arguments) (%tool-arguments t) arguments) (%tool-state t) (%tool-output t)
                          (%tool-images t) (%tool-duration t))]
      [else (%make-tool-call id name arguments (tool-state called) "" 0 #f)])))

(define (%reply-parts chat content)
  (if (vector? content)
      (let loop ([blocks (vector->list content)] [acc '()])
        (if (null? blocks)
            (reverse acc)
            (let* ([b (car blocks)] [type (ref b "type")])
              (loop (cdr blocks)
                    (cond
                      [(equal? type "text") (cons (%make-text (or (ref b "text") "")) acc)]
                      [(equal? type "thinking") (cons (%make-thinking (or (ref b "thinking") "")) acc)]
                      [(equal? type "toolCall") (cons (%tool-call-of chat b) acc)]
                      [else acc])))))
      '()))

(define (%live-parts->content parts)
  (list->vector
    (map (lambda (p)
           (let ([type (live-part-type p)] [text (apply string-append (reverse (live-part-pieces p)))])
             (cond
               [(equal? type "text") (list '("type" . "text") (cons "text" text))]
               [(equal? type "thinking") (list '("type" . "thinking") (cons "thinking" text))]
               [else (list '("type" . "toolCall") (cons "id" (live-part-id p)) (cons "name" (live-part-name p))
                           (cons "arguments" (or (live-part-arguments p) '())))])))
         (vector->list (vector-map unbox parts)))))

(define (%text-part type pieces) (make-live-part type pieces #f #f #f))

(define (%live->item chat l)
  (let ([k (live-key l)] [m (live-message l)])
    (cond
      [(and (equal? (live-role l) "assistant") (not (live-ended? l)))
       (%make-reply k #f (%reply-parts chat (%live-parts->content (live-parts l))) (stop pending) #f (and m (ref m "model")))]
      [m (%message->item chat m k #f)]
      [else #f])))

(define (%apply-entries! chat data)
  (let ([entries (ref data "entries")] [table (%chat-entries chat)])
    (when (vector? entries)
      (vector-for-each (lambda (e) (let ([id (ref e "id")]) (when id (hashtable-set! table id e)))) entries)
      (when (fx> (vector-length entries) 0)
        (let ([last-id (ref (vector-ref entries (fx- (vector-length entries) 1)) "id")])
          (when last-id (%chat-cursor-set! chat last-id)))))
    (%chat-leaf-set! chat (ref data "leafId"))
    (let ([items (%entry-items chat)])
      (%chat-items-set! chat items)
      ;; A message seen ending before this answer is among the entries;
      ;; one still being written stays live after them.
      (%chat-live-set! chat
        (let loop ([ls (%chat-live chat)] [k (vector-length items)] [acc '()])
          (cond
            [(null? ls) (reverse acc)]
            [(live-ended? (car ls)) (loop (cdr ls) k acc)]
            [else (live-key-set! (car ls) k) (loop (cdr ls) (fx+ k 1) (cons (car ls) acc))]))))
    (let ([link (%chat-link chat)])
      (when (and link (link-replaying? link))
        (link-replaying?-set! link #f)
        (%chat-answered-set! chat (filter (lambda (id) (member id (link-seen link))) (%chat-answered chat)))
        (link-seen-set! link '())
        (%save!)))
    (%changed! chat)))

(define (%item-count chat)
  (fx+ (vector-length (%chat-items chat)) (length (%chat-live chat))))

(define (%transcript chat)
  (or (%chat-transcript-cache chat)
      (let* ([items (vector->list (%chat-items chat))]
             [items (map (lambda (item)
                           (if (and (reply? item)
                                    (exists (lambda (p) (and (tool-call? p) (memq (tool-call-state p) (list (tool-state called) (tool-state running)))))
                                            (reply-parts item)))
                               (let ([e (hashtable-ref (%chat-entries chat) (item-entry-id item) #f)])
                                 (or (and e (%entry->item chat e (item-key item))) item))
                               item))
                         items)]
             [live (filter values (map (lambda (l) (%live->item chat l)) (%chat-live chat)))]
             [all (append items live)]
             [with-notices
               (let loop ([all all] [notices (reverse (%chat-notices chat))] [k 0] [acc '()])
                 (cond
                   [(and (pair? notices) (<= (car (item-key (car notices))) k))
                    (loop all (cdr notices) k (cons (car notices) acc))]
                   [(null? all) (append (reverse acc) notices)]
                   [else (loop (cdr all) notices (fx+ k 1) (cons (car all) acc))]))])
        (%chat-transcript-cache-set! chat with-notices)
        with-notices)))

(define (%notice! chat level text)
  (let ([after (%item-count chat)])
    (%chat-notices-set! chat
      (cons (%make-notice (cons after (length (%chat-notices chat))) #f level text) (%chat-notices chat)))
    (%changed! chat)))

(define (%current-live chat)
  (let ([ls (%chat-live chat)])
    (and (pair? ls)
         (let ([l (car (last-pair ls))])
           (and (not (live-ended? l)) l)))))

(define (%start-live! chat m)
  (let ([l (make-live (or (ref m "role") "") (%item-count chat) (vector) m #f)])
    (%chat-live-set! chat (append (%chat-live chat) (list l)))
    l))

(define (%part-box! l index)
  (let ([parts (live-parts l)])
    (when (>= index (vector-length parts))
      (live-parts-set! l
        (let ([grown (make-vector (+ index 1) #f)])
          (do ([i 0 (+ i 1)]) ((> i index) grown)
            (vector-set! grown i (if (< i (vector-length parts)) (vector-ref parts i) (box (%text-part "text" '()))))))))
    (vector-ref (live-parts l) index)))

(define (%apply-update! chat event)
  (let* ([l (or (%current-live chat) (%start-live! chat '(("role" . "assistant"))))]
         [type (ref event "type")] [index (or (ref event "contentIndex") 0)])
    (cond
      [(equal? type "text_start") (set-box! (%part-box! l index) (%text-part "text" '())) (%set-activity! chat (activity replying))]
      [(equal? type "text_delta")
       (let ([b (%part-box! l index)])
         (set-box! b (%text-part "text" (cons (or (ref event "delta") "") (live-part-pieces (unbox b))))))
       (%set-activity! chat (activity replying))]
      [(equal? type "text_end") (set-box! (%part-box! l index) (%text-part "text" (list (or (ref event "content") ""))))]
      [(equal? type "thinking_start") (set-box! (%part-box! l index) (%text-part "thinking" '())) (%set-activity! chat (activity thinking))]
      [(equal? type "thinking_delta")
       (let ([b (%part-box! l index)])
         (set-box! b (%text-part "thinking" (cons (or (ref event "delta") "") (live-part-pieces (unbox b))))))
       (%set-activity! chat (activity thinking))]
      [(equal? type "thinking_end") (set-box! (%part-box! l index) (%text-part "thinking" (list (or (ref event "content") ""))))]
      [(equal? type "toolcall_start")
       (set-box! (%part-box! l index)
         (make-live-part "toolCall" '() (or (ref event "id") "") (or (ref event "toolName") "") #f))
       (%set-activity! chat (activity replying))]
      [(equal? type "toolcall_end")
       (let ([call (ref event "toolCall")])
         (set-box! (%part-box! l index)
           (make-live-part "toolCall" '() (or (ref call "id") "") (or (ref call "name") "") (ref call "arguments"))))]
      [else (void)])))

(define (%end-live! chat m)
  (let ([l (or (let ([l (%current-live chat)]) (and l (equal? (live-role l) (ref m "role")) l))
               (%start-live! chat m))])
    (live-message-set! l m)
    (live-ended?-set! l #t)))

(define (%dialog-of request)
  (let ([kind (ref request "method")])
    (%make-dialog (ref request "id")
                  (cond [(equal? kind "select") (method select)] [(equal? kind "confirm") (method confirm)]
                        [(equal? kind "input") (method input)] [else (method editor)])
                  (or (ref request "title") "")
                  (ref request "message")
                  (let ([o (ref request "options")]) (if (vector? o) (filter string? (vector->list o)) '()))
                  (or (ref request "placeholder") (ref request "prefill"))
                  (now-ms)
                  (let ([t (ref request "timeout")]) (and (number? t) (exact (round t)))))))

(define (%add-dialog! chat d)
  (unless (exists (lambda (o) (equal? (dialog-id o) (dialog-id d))) (%chat-dialogs chat))
    (%chat-dialogs-set! chat (append (%chat-dialogs chat) (list d)))
    (%watch-deadline! chat d)
    (%save!)
    (%changed! chat)))

(define (%watch-deadline! chat d)
  (when (%dialog-timeout d)
    (let ([left (/ (- (+ (%dialog-arrived d) (%dialog-timeout d)) (now-ms)) 1000)])
      (%chat-timers-set! chat
        (cons (as-module (this-module)
                (run-with-timer (max 0 (inexact left)) (lambda () (%drop-dialog! chat d))))
              (%chat-timers chat))))))

(define (%drop-dialog! chat d)
  (when (memq d (%chat-dialogs chat))
    (%chat-dialogs-set! chat (remq d (%chat-dialogs chat)))
    (%chat-answered-set! chat (cons (dialog-id d) (%chat-answered chat)))
    (%save!)
    (%changed! chat)))

;; Pi's protocol carries a widget only as lines of text, so an extension
;; that reports to programs, as pi-subagents does, writes its data as a
;; line such as PI_SUBAGENT_ASYNC_JSON:{...}, which is not for people.
;; The rest must parse as an object or array, or prose such as
;; "NOTE: {x}" would vanish.
(define (%machine-line? line)
  (let ([n (string-length line)])
    (and (fx> n 0) (char<=? #\A (string-ref line 0) #\Z)
         (let loop ([i 1])
           (and (fx< i n)
                (let ([c (string-ref line i)])
                  (cond
                    [(char=? c #\:)
                     (let ([v (guard (e [(json-error? e) #f]) (string->json (substring line (fx+ i 1) n)))])
                       (or (list? v) (vector? v)))]
                    [(or (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\_)) (loop (fx+ i 1))]
                    [else #f])))))))

(define (%ui-request! chat link request)
  (let ([kind (ref request "method")] [replaying? (link-replaying? link)])
    (cond
      [(member kind '("select" "confirm" "input" "editor"))
       (let ([id (ref request "id")])
         (when replaying? (link-seen-set! link (cons id (link-seen link))))
         (unless (or (member id (%chat-answered chat)) (not (string? id)))
           (%add-dialog! chat (%dialog-of request))))]
      [(equal? kind "notify")
       (unless replaying?
         (%notice! chat (let ([t (ref request "notifyType")])
                          (cond [(equal? t "warning") 'warning] [(equal? t "error") 'error] [else 'info]))
                   (or (ref request "message") "")))]
      [(equal? kind "setStatus")
       (let ([key (ref request "statusKey")] [text (ref request "statusText")])
         (when (string? key)
           (%chat-statuses-set! chat
             (let ([others (remp (lambda (s) (equal? (car s) key)) (%chat-statuses chat))])
               (if (string? text) (append others (list (cons key text))) others)))
           (%save!)
           (%changed! chat)))]
      [(equal? kind "setWidget")
       (let* ([key (ref request "widgetKey")]
              [lines (let ([v (ref request "widgetLines")]) (and (vector? v) (filter string? (vector->list v))))]
              [drawn (and lines (remp %machine-line? lines))])
         (when (string? key)
           (%chat-widgets-set! chat
             (let ([others (remp (lambda (w) (equal? (widget-key w) key)) (%chat-widgets chat))])
               (if (and lines (or (null? lines) (pair? drawn)))
                   (append others
                     (list (%make-widget key
                             (if (equal? (ref request "widgetPlacement") "belowEditor") 'below 'above)
                             drawn)))
                   others)))
           (%save!)
           (%changed! chat)))]
      [(equal? kind "set_editor_text")
       (unless replaying?
         (editor-text-requested chat (or (ref request "text") "")))]
      [else (void)])))

(define (%after-run! chat)
  (%set-activity! chat (activity idle))
  (%chat-running?-set! chat #f)
  (let-values ([(ids tools) (hashtable-entries (%chat-tools chat))])
    (vector-for-each (lambda (t) (when (eq? (%tool-state t) (tool-state running)) (%tool-state-set! t (tool-state failed)))) tools))
  (%chat-live-set! chat (filter live-ended? (%chat-live chat)))
  (%refresh-entries! chat)
  (%refresh-state! chat)
  (%refresh-stats! chat)
  (%refresh-commands! chat))

(define (%busy-activity chat)
  (let-values ([(ids tools) (hashtable-entries (%chat-tools chat))])
    (if (exists (lambda (t) (eq? (%tool-state t) (tool-state running))) (vector->list tools))
        (activity running)
        (activity thinking))))

(define (%record! chat link record)
  (let ([type (ref record "type")])
    (cond
      [(equal? type "response")
       (let ([handlers (let ([id (ref record "id")]) (and (string? id) (hashtable-ref (link-pending link) id #f)))])
         (when handlers
           (hashtable-delete! (link-pending link) (ref record "id"))
           (let ([failure (%response-failure record)])
             (if failure ((cdr handlers) failure) ((car handlers) (ref record "data"))))))]
      ;; A restart's Pi speaks before its answer makes it the chat's: its
      ;; extensions set statuses and may ask a question as it starts.
      [(not (eq? link (%chat-link chat)))
       (unless (link-ended? link)
         (link-held-set! link (cons record (link-held link))))]
      [(equal? type "extension_ui_request") (%ui-request! chat link record)]
      [(equal? type "agent_start")
       (%chat-running?-set! chat #t)
       (%set-activity! chat (activity thinking))]
      [(equal? type "agent_settled") (%after-run! chat)]
      [(equal? type "message_start")
       (let ([m (ref record "message")])
         (when (equal? (ref m "role") "assistant")
           (%start-live! chat m)
           (%set-activity! chat (activity thinking))))]
      [(equal? type "message_update") (%apply-update! chat (ref record "assistantMessageEvent"))]
      [(equal? type "message_end")
       (let ([m (ref record "message")])
         (when (member (ref m "role") '("user" "assistant" "custom" "bashExecution"))
           (%end-live! chat m)))]
      [(equal? type "tool_execution_start")
       (hashtable-set! (%chat-tools chat) (or (ref record "toolCallId") "")
         (make-tool (or (ref record "toolName") "") (or (ref record "args") '()) (tool-state running) "" 0 #f))
       (%set-activity! chat (activity running))]
      [(equal? type "tool_execution_update")
       (let ([t (hashtable-ref (%chat-tools chat) (or (ref record "toolCallId") "") #f)])
         (when t
           (%tool-output-set! t (text-of (ref (ref record "partialResult") "content")))))]
      [(equal? type "tool_execution_end")
       (let ([t (hashtable-ref (%chat-tools chat) (or (ref record "toolCallId") "") #f)]
             [result (ref record "result")])
         (when t
           (%tool-state-set! t (if (eq? (ref record "isError") #t) (tool-state failed) (tool-state done)))
           (%tool-output-set! t (text-of (ref result "content")))
           (%tool-images-set! t (%images-in (ref result "content")))
           (%tool-duration-set! t (let ([ms (ref record "durationMs")]) (and (number? ms) (/ ms 1000)))))
         (when (eq? (%chat-activity chat) (activity running)) (%set-activity! chat (%busy-activity chat))))]
      [(equal? type "queue_update")
       (%chat-steering-set! chat (let ([v (ref record "steering")]) (if (vector? v) (filter string? (vector->list v)) '())))
       (%chat-follow-ups-set! chat (let ([v (ref record "followUp")]) (if (vector? v) (filter string? (vector->list v)) '())))
       (%save!)]
      [(equal? type "compaction_start")
       (%set-activity! chat (activity compacting))]
      [(equal? type "compaction_end")
       (%set-activity! chat (if (%chat-running? chat) (%busy-activity chat) (activity idle)))
       (let ([failure (ref record "errorMessage")])
         (when failure (%notice! chat 'error (string-append "Compaction failed: " failure))))
       (%refresh-entries! chat)
       (%refresh-stats! chat)]
      [(equal? type "auto_retry_start") (%set-activity! chat (activity retrying))]
      [(equal? type "auto_retry_end")
       (unless (eq? (ref record "success") #t)
         (%notice! chat 'error (string-append "Retrying failed: " (or (ref record "finalError") ""))))
       (%set-activity! chat (%busy-activity chat))]
      [(equal? type "session_info_changed") (%chat-session-name-set! chat (ref record "name"))]
      [(equal? type "thinking_level_changed") (%chat-thinking-level-set! chat (ref record "level"))]
      [(equal? type "entry_appended") (%refresh-entries! chat)]
      [(equal? type "extension_error")
       (%notice! chat 'error
         (string-append "Extension " (or (ref record "extensionPath") "") ": " (or (ref record "error") "")))]
      [else (void)])
    (when (eq? link (%chat-link chat))
      (%changed! chat))))

(define (%parsed! chat link value)
  (cond
    [(eq? value 'end)
     (link-parsed-end?-set! link #t)
     (%maybe-ended! chat link)]
    [(pair? (cdr value)) (%record! chat link (cdr value))]
    [else (void)]))

(define (%exited! chat link status)
  (link-status-set! link status)
  (%maybe-ended! chat link))

;; Pi's exit is handled once its job has passed on every line before it.
(define (%maybe-ended! chat link)
  (when (and (link-status link) (link-parsed-end? link) (not (link-ended? link)))
    (link-ended?-set! link #t)
    (jobs:stop! (link-job link))
    (%fail-pending! link "Pi has ended")
    (when (eq? link (%chat-link chat))
      (let ([status (link-status link)])
        (%notice! chat 'error
          (if (condition? status)
              (string-append "Pi could not start: "
                             (if (message-condition? status) (condition-message status) "it did not run")
                             ". pi:command is " (format "~s" (command)) ".")
              (string-append "Pi exited with status " (number->string status) "."
                             (let ([err (processes:error-output (link-process link))])
                               (if (and err (fx> (bytevector-length err) 0))
                                   (string-append "\n" (%last-lines (utf8->string err) 20))
                                   ""))))))
      (%chat-dialogs-set! chat '())
      (%chat-statuses-set! chat '())
      (%chat-widgets-set! chat '())
      (%chat-steering-set! chat '())
      (%chat-follow-ups-set! chat '())
      (%chat-live-set! chat (filter live-ended? (%chat-live chat)))
      (%set-activity! chat (activity exited))
      (%save!)
      (%changed! chat))))

(define (%last-lines text n)
  (let loop ([i (string-length text)] [count 0])
    (cond
      [(fx= i 0) text]
      [(and (char=? (string-ref text (fx- i 1)) #\newline) (fx< i (string-length text)))
       (if (fx= (fx+ count 1) n) (substring text i (string-length text)) (loop (fx- i 1) (fx+ count 1)))]
      [else (loop (fx- i 1) count)])))

;; The attachment and the job are pi's own, not the calling module's, so
;; that module's reload leaves the chat followed.
(define (%follow! chat process replaying?)
  (let ([link (make-link process replaying?)])
    (as-module (this-module)
      (link-job-set! link
        (jobs:start %parser #f (lambda (value) (%parsed! chat link value))))
      (processes:attach! process 0
        (lambda (bytes end)
          (unless (link-ended? link)
            (if (eof-object? bytes)
                (%end-parsing! link)
                (jobs:send! (link-job link) (cons bytes end)))))
        (lambda (status)
          (%end-parsing! link)
          (%exited! chat link status))))
    link))

;; A process that is stopped, or that never started, delivers its exit
;; without an end of output.
(define (%end-parsing! link)
  (unless (link-end-sent? link)
    (link-end-sent?-set! link #t)
    (jobs:send! (link-job link) 'end)))

(define (%launch chat session-id)
  (let ([cmd (command)])
    (processes:start-for-user (car cmd)
      (append (cdr cmd) (list "--mode" "rpc" "--session-id" session-id))
      (processes:options [directory (%chat-directory chat)] [separate-stderr #t]
                         [full-log (processes:full-log pause)]))))

(define (%start-process! chat)
  (let ([link (%follow! chat (%launch chat (%chat-session-id chat)) #f)])
    (%chat-link-set! chat link)
    (%set-activity! chat (activity starting))
    (%save!)
    (%refresh-all! chat)))

(define (%revive! saved)
  (let* ([process (and (vector-ref saved 0) (processes:find (vector-ref saved 0)))]
         [chat (make-chat (vector-ref saved 2) (vector-ref saved 1))])
    (set! %live-chats (append %live-chats (list chat)))
    (cond
      [process
       (let-values ([(open expired)
                     (let ([now (now-ms)])
                       (partition (lambda (d) (or (not (%dialog-timeout d)) (< now (+ (%dialog-arrived d) (%dialog-timeout d)))))
                                  (map %saved->dialog (vector-ref saved 3))))])
         (%chat-dialogs-set! chat open)
         (%chat-answered-set! chat (append (map dialog-id expired) (vector-ref saved 8))))
       (for-each (lambda (d) (%watch-deadline! chat d)) (%chat-dialogs chat))
       (%chat-statuses-set! chat (vector-ref saved 4))
       (%chat-widgets-set! chat
         (map (lambda (w) (%make-widget (vector-ref w 0) (vector-ref w 1) (vector-ref w 2))) (vector-ref saved 5)))
       (%chat-steering-set! chat (vector-ref saved 6))
       (%chat-follow-ups-set! chat (vector-ref saved 7))
       (%chat-link-set! chat (%follow! chat process #t))
       (%refresh-all! chat)]
      ;; The configuration's setting of pi:command arrives after this body
      ;; runs, and so before the task starts.
      [else
       (spawn-task
         (lambda ()
           (when (and (memq chat %live-chats) (not (%chat-link chat)))
             (%start-process! chat)
             (%changed! chat))))])))

(define start
  (case-lambda
    [(directory) (start directory #f)]
    [(directory session-id)
     (%check-directory 'pi:start directory)
     (unless (or (not session-id) (string? session-id))
       (assertion-violation 'pi:start "not a session id" session-id))
     (when %version-refusal
       (error 'pi:start %version-refusal))
     (or (and session-id
              (find (lambda (c) (equal? (%chat-session-id c) session-id)) %live-chats))
         (let ([chat (make-chat directory (or session-id (make-session-id)))])
           (set! %live-chats (append %live-chats (list chat)))
           (%start-process! chat)
           (%changed! chat)
           chat))]))

(define (chats) %live-chats)

(define (chat? v) (chat-record? v))

(define (chat-directory chat)
  (%check-chat 'pi:chat-directory chat)
  (%chat-directory chat))

(define (chat-process chat)
  (%check-chat 'pi:chat-process chat)
  (let ([link (%chat-link chat)]) (and link (link-process link))))

(define (chat-working? chat)
  (%check-chat 'pi:chat-working? chat)
  (not (memq (%chat-activity chat) (list (activity idle) (activity exited) (activity starting)))))

(define (restart! chat)
  (%check-chat 'pi:restart! chat)
  (when (chat-working? chat)
    (%refuse 'pi:restart! "Pi is working; two Pis on one session would each write their own tree"))
  (let ([old (%chat-link chat)])
    (let ([new (%follow! chat (%launch chat (%chat-session-id chat)) #f)])
      (suspend
        (lambda (resume)
          (as-module (this-module)
            (%request! new '(("type" . "get_state"))
              (lambda (data)
                (resume
                  (lambda ()
                    (when (and old (not (link-ended? old)))
                      (link-ended?-set! old #t)
                      (%fail-pending! old "Pi was restarted")
                      (jobs:stop! (link-job old))
                      (processes:stop! (link-process old)))
                    (%chat-link-set! chat new)
                    (%chat-dialogs-set! chat '())
                    (%chat-statuses-set! chat '())
                    (%chat-widgets-set! chat '())
                    (hashtable-clear! (%chat-tools chat))
                    (%chat-live-set! chat '())
                    (%chat-notices-set! chat '())
                    (%set-activity! chat (activity idle))
                    (let ([held (reverse (link-held new))])
                      (link-held-set! new '())
                      (for-each (lambda (record) (%record! chat new record)) held))
                    (%save!)
                    (%refresh-all! chat)
                    (%changed! chat))))
              (lambda (message)
                (resume
                  (lambda ()
                    (processes:stop! (link-process new))
                    (%refuse 'pi:restart! message)))))))))))

(define (stop! chat)
  (%check-chat 'pi:stop! chat)
  (when (memq chat %live-chats)
    (set! %live-chats (remq chat %live-chats))
    (for-each cancel-timer! (%chat-timers chat))
    (let ([link (%chat-link chat)])
      (when link
        (link-ended?-set! link #t)
        (%fail-pending! link "the chat was stopped")
        (when (link-job link) (jobs:stop! (link-job link)))
        (processes:stop! (link-process link))))
    (%save!)
    (chat-changed chat)))

(define (chat-transcript chat)
  (%check-chat 'pi:chat-transcript chat)
  (%transcript chat))

(define (chat-activity chat)
  (%check-chat 'pi:chat-activity chat)
  (%chat-activity chat))

(define (chat-queue chat)
  (%check-chat 'pi:chat-queue chat)
  (values (%chat-steering chat) (%chat-follow-ups chat)))

(define (chat-statuses chat)
  (%check-chat 'pi:chat-statuses chat)
  (%chat-statuses chat))

(define (chat-widgets chat)
  (%check-chat 'pi:chat-widgets chat)
  (%chat-widgets chat))

(define (chat-model chat)
  (%check-chat 'pi:chat-model chat)
  (%chat-model chat))

(define (chat-thinking-level chat)
  (%check-chat 'pi:chat-thinking-level chat)
  (%chat-thinking-level chat))

(define (chat-session-id chat)
  (%check-chat 'pi:chat-session-id chat)
  (%chat-session-id chat))

(define (chat-session-file chat)
  (%check-chat 'pi:chat-session-file chat)
  (%chat-session-file chat))

(define (chat-session-name chat)
  (%check-chat 'pi:chat-session-name chat)
  (%chat-session-name chat))

(define (chat-auto-compaction? chat)
  (%check-chat 'pi:chat-auto-compaction? chat)
  (%chat-auto-compaction? chat))

(define (chat-usage chat)
  (%check-chat 'pi:chat-usage chat)
  (%chat-usage chat))

(define (chat-commands chat)
  (%check-chat 'pi:chat-commands chat)
  (%chat-commands chat))

(define (chat-dialogs chat)
  (%check-chat 'pi:chat-dialogs chat)
  (%chat-dialogs chat))

(define (dialog-deadline d)
  (%check-dialog 'pi:dialog-deadline d)
  (and (%dialog-timeout d) (ms->time (+ (%dialog-arrived d) (%dialog-timeout d)))))

(define (%respond! who chat d obj)
  (%check-chat who chat)
  (%check-dialog who d)
  (when (memq d (%chat-dialogs chat))
    (%chat-dialogs-set! chat (remq d (%chat-dialogs chat)))
    (%chat-answered-set! chat (cons (dialog-id d) (%chat-answered chat)))
    (let ([link (%chat-link chat)])
      (when (and link (not (link-ended? link)))
        (%send-json! link (append (list '("type" . "extension_ui_response") (cons "id" (dialog-id d))) obj))))
    (%save!)
    (%changed! chat)))

(define (answer! chat d value)
  (%check-dialog 'pi:answer! d)
  (if (eq? (dialog-method d) (method confirm))
      (unless (boolean? value)
        (assertion-violation 'pi:answer! "not a boolean" value))
      (unless (string? value)
        (assertion-violation 'pi:answer! "not a string" value)))
  (%respond! 'pi:answer! chat d (if (boolean? value) (list (cons "confirmed" value)) (list (cons "value" value)))))

(define (cancel! chat d)
  (%respond! 'pi:cancel! chat d '(("cancelled" . #t))))

(define (%prompt! who chat text behaviour)
  (%check-chat who chat)
  (unless (string? text)
    (assertion-violation who "not a string" text))
  (let ([data (%call chat who (list '("type" . "prompt") (cons "message" text) (cons "streamingBehavior" behaviour)))])
    ;; A command Pi handles itself starts no run, so no settle follows to
    ;; read what it added to the session.
    (when (equal? (ref data "disposition") "handled")
      (%refresh-entries! chat)
      (%refresh-state! chat))
    (void)))

(define (send! chat text) (%prompt! 'pi:send! chat text "steer"))

(define (follow-up! chat text) (%prompt! 'pi:follow-up! chat text "followUp"))

(define (%queue-texts data)
  (append (let ([v (ref data "steering")]) (if (vector? v) (vector->list v) '()))
          (let ([v (ref data "followUp")]) (if (vector? v) (vector->list v) '()))))

(define (take-queue! chat)
  (%check-chat 'pi:take-queue! chat)
  (%queue-texts (%call chat 'pi:take-queue! '(("type" . "clear_queue")))))

(define (abort! chat)
  (%check-chat 'pi:abort! chat)
  (let ([texts (%queue-texts (%call chat 'pi:abort! '(("type" . "clear_queue"))))])
    (%call chat 'pi:abort! '(("type" . "abort")))
    texts))

(define (%after-session-change! chat)
  (hashtable-clear! (%chat-tools chat))
  (%chat-live-set! chat '())
  (%chat-notices-set! chat '())
  (%chat-items-set! chat '#())
  (%refresh-all! chat)
  (%changed! chat))

(define (new-session! chat)
  (%check-chat 'pi:new-session! chat)
  (%call chat 'pi:new-session! '(("type" . "new_session")))
  (%after-session-change! chat))

(define (switch-session! chat file)
  (%check-chat 'pi:switch-session! chat)
  (unless (string? file)
    (assertion-violation 'pi:switch-session! "not a string" file))
  (%call chat 'pi:switch-session! (list '("type" . "switch_session") (cons "sessionPath" file)))
  (%after-session-change! chat))

(define (fork-messages chat)
  (%check-chat 'pi:fork-messages chat)
  (let ([messages (ref (%call chat 'pi:fork-messages '(("type" . "get_fork_messages"))) "messages")])
    (if (vector? messages)
        (map (lambda (m) (cons (or (ref m "entryId") "") (or (ref m "text") ""))) (vector->list messages))
        '())))

(define (fork! chat entry-id)
  (%check-chat 'pi:fork! chat)
  (unless (string? entry-id)
    (assertion-violation 'pi:fork! "not an entry id" entry-id))
  (let ([data (%call chat 'pi:fork! (list '("type" . "fork") (cons "entryId" entry-id)))])
    (%after-session-change! chat)
    (or (ref data "text") "")))

(define (clone! chat)
  (%check-chat 'pi:clone! chat)
  (%call chat 'pi:clone! '(("type" . "clone")))
  (%after-session-change! chat))

(define (set-session-name! chat name)
  (%check-chat 'pi:set-session-name! chat)
  (unless (string? name)
    (assertion-violation 'pi:set-session-name! "not a string" name))
  (%call chat 'pi:set-session-name! (list '("type" . "set_session_name") (cons "name" name)))
  (%chat-session-name-set! chat name)
  (%changed! chat))

(define compact!
  (case-lambda
    [(chat) (compact! chat #f)]
    [(chat instructions)
     (%check-chat 'pi:compact! chat)
     (unless (or (not instructions) (string? instructions))
       (assertion-violation 'pi:compact! "not a string" instructions))
     (%call chat 'pi:compact!
       (if (and instructions (not (string=? instructions "")))
           (list '("type" . "compact") (cons "customInstructions" instructions))
           '(("type" . "compact"))))
     (%refresh-entries! chat)
     (%refresh-stats! chat)
     (void)]))

(define (set-auto-compaction! chat on?)
  (%check-chat 'pi:set-auto-compaction! chat)
  (%call chat 'pi:set-auto-compaction! (list '("type" . "set_auto_compaction") (cons "enabled" (and on? #t))))
  (%chat-auto-compaction?-set! chat (and on? #t))
  (%changed! chat))

(define (models chat)
  (%check-chat 'pi:models chat)
  (let ([ms (ref (%call chat 'pi:models '(("type" . "get_available_models"))) "models")])
    (if (vector? ms) (filter values (map %model-of (vector->list ms))) '())))

(define (set-model! chat m)
  (%check-chat 'pi:set-model! chat)
  (unless (model? m)
    (assertion-violation 'pi:set-model! "not a model" m))
  (%chat-model-set! chat
    (or (%model-of (%call chat 'pi:set-model!
                     (list '("type" . "set_model") (cons "provider" (model-provider m)) (cons "modelId" (model-id m)))))
        m))
  (%refresh-state! chat)
  (%changed! chat))

(define (thinking-levels chat)
  (%check-chat 'pi:thinking-levels chat)
  (let ([levels (ref (%call chat 'pi:thinking-levels '(("type" . "get_available_thinking_levels"))) "levels")])
    (if (vector? levels) (filter string? (vector->list levels)) '())))

(define (set-thinking-level! chat level)
  (%check-chat 'pi:set-thinking-level! chat)
  (unless (string? level)
    (assertion-violation 'pi:set-thinking-level! "not a string" level))
  (%call chat 'pi:set-thinking-level! (list '("type" . "set_thinking_level") (cons "level" level)))
  (%chat-thinking-level-set! chat level)
  (%changed! chat))

(define export-html!
  (case-lambda
    [(chat) (export-html! chat #f)]
    [(chat path)
     (%check-chat 'pi:export-html! chat)
     (unless (or (not path) (string? path))
       (assertion-violation 'pi:export-html! "not a string" path))
     (or (ref (%call chat 'pi:export-html!
                (if path (list '("type" . "export_html") (cons "outputPath" path)) '(("type" . "export_html"))))
              "path")
         "")]))

(define (last-reply chat)
  (%check-chat 'pi:last-reply chat)
  (let ([text (ref (%call chat 'pi:last-reply '(("type" . "get_last_assistant_text"))) "text")])
    (and (string? text) text)))

(define (%agent-folder)
  (let ([dir (getenv "PI_CODING_AGENT_DIR")])
    (cond
      [(and dir (not (string=? dir ""))) dir]
      [else (string-append (or (getenv "HOME") "") "/.pi/agent")])))

(define (%session-folder directory)
  (let* ([d (let loop ([d directory])
              (if (and (fx> (string-length d) 1) (char=? (string-ref d (fx- (string-length d) 1)) #\/))
                  (loop (substring d 0 (fx- (string-length d) 1)))
                  d))]
         [d (substring d 1 (string-length d))])
    (string-append (%agent-folder) "/sessions/--"
                   (list->string (map (lambda (c) (if (memv c '(#\/ #\\ #\:)) #\- c)) (string->list d)))
                   "--")))

(define (sessions directory)
  (%check-directory 'pi:sessions directory)
  (let ([found
         (suspend
           (lambda (resume)
             (as-module (this-module)
               (let ([result '()])
                 (jobs:start %session-lister (%session-folder directory)
                   (lambda (v) (set! result v))
                   (lambda (ended) (resume (lambda () (if (condition? ended) (raise ended) result)))))))))])
    (sort (lambda (a b) (time>? (session-modified a) (session-modified b)))
          (map (lambda (v)
                 (%make-session (vector-ref v 0) (vector-ref v 1) (vector-ref v 2) (vector-ref v 3) (vector-ref v 4)
                                (make-time 'time-utc (cdr (vector-ref v 5)) (car (vector-ref v 5)))))
               found))))

(define (%command-changed option value)
  (when (eq? option command)
    (spawn-task %check-version!)))

;; A task waiting for Pi's answer would wait for ever once nothing follows
;; Pi for this instance of pi.
(on-unload
  (lambda ()
    (for-each
      (lambda (chat)
        (let ([link (%chat-link chat)])
          (when link
            (let-values ([(ids handlers) (hashtable-entries (link-pending link))])
              (hashtable-clear! (link-pending link))
              (vector-for-each (lambda (h) ((cdr h) "pi was unloaded")) handlers)))))
      %live-chats)))

(add-hook! option-changed %command-changed)

(spawn-task %check-version!)

(for-each %revive! (%chats))
