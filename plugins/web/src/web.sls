#!tuna
(import (h2o) (datastar) (json) (haml) (hooks) (options) (tables) (timers))

(define %self (current-owner))

;; The server's threads run this code, so none of it may be a top-level
;; definition, which can change under a running thread.
(module %internals
  (client-record? code-client? connected-clients give-screen! call-page ask-and-wait start-server! restart-server!
   stop-server! allow-hosts! refresh-head-files! refresh-upload-handlers! post-start! release-first-screens!
   home-path? valid-name? on-main-thread? open-code-client! post-code-input! close-code-client! close-owner-clients!
   wait-until-applied listening-url as-page-would suspend-for-client-input)

  (define main-thread (get-thread-id))
  (define lock (make-mutex))
  (define wake (make-condition))

  ;; A cancel inside the lock would leave a client half changed, so the
  ;; lock is held masked; a body must not wait.
  (define-syntax with-lock
    (syntax-rules ()
      [(_ e1 e2 ...)
       (call-with-cancellation-masked (lambda (restore) (with-mutex lock e1 e2 ...)))]))

  ;; Only the main thread uses through and removal-timer; the lock guards
  ;; the other mutable fields.
  ;; FIRST is the screen the page carries: #f until a batch draws one,
  ;; and the symbol served once the page has gone with it. TITLE is the
  ;; one the page shows, as far as this plugin knows; #f when it cannot
  ;; know, after the page's stream was opened again.
  (define-record-type (client make-client client-record?)
    (sealed #t)
    (fields id number code pending (mutable next) (mutable removed?) (mutable stream)
            (mutable through) (mutable removal-timer)
            (mutable last) (mutable count) (mutable in-flight) (mutable sent-at) (mutable unconfirmed)
            (mutable waiting) (mutable calls) (mutable links) (mutable scripts-version) (mutable title) (mutable first)
            (mutable asks) (mutable held) (mutable deferred) (mutable item-tasks) (mutable quit-cancelled)
            (mutable input-readers) (mutable applied-waiters))
    (protocol
      (lambda (new)
        (lambda (id number code links scripts-version)
          (new id number code (make-eqv-hashtable) 1 #f #f 0 #f #f 0 #f 0 '() #f '() links scripts-version "Tuna" #f
               '() 0 '() '() #f '() '())))))

  (define-record-type code-page
    (sealed #t)
    (fields receive-screen receive-call answer owner))

  (define-record-type code-question
    (sealed #t)
    (fields id name value))

  (define (code-client? v)
    (and (client-record? v) (client-code v) #t))

  (define (on-main-thread?) (fx= (get-thread-id) main-thread))

  (define-record-type head-file
    (sealed #t)
    (fields slot path time bytes version))

  (define configuration-folder (string-append (getenv "HOME") "/.config/tuna"))

  (define clients-by-id (make-hashtable string-hash string=?))
  (define connected '())
  (define opening '())
  (define code-clients '())
  (define first-screens (make-condition))
  (define added 0)
  (define queued 0)
  (define outbox '())
  (define sender #f)
  (define server #f)
  (define server-settings #f)
  (define started? #f)
  (define start-posted? #f)
  (define allowed '())
  (define proxy-secret #f)
  (define reported-types '())
  (define listening-port #f)
  (define first-free-port 7337)

  (define stylesheet-entries '())
  (define script-entries '())
  (define stylesheet-files '())
  (define script-files '())
  (define slots (make-hashtable equal-hash equal?))
  (define links '())
  (define script-hrefs '())
  (define early-entries '())
  (define early-files '())
  (define early-hrefs '())
  (define upload-entries '())
  (define uploads '())
  (define scripts-version 0)
  (define files-checked 0)

  (define max-held-items 10000)

  (define questions (make-eqv-hashtable))
  (define last-question 0)
  (define confirmation-wait 1000)

  ;; What the stream library holds for a page that has not read it yet,
  ;; at most; past it the library fails the stream.
  (define stream-limit (* 4 1024 1024))
  (define removal-seconds 3600)
  (define heartbeat-seconds 15)

  ;; From the first step of web's unload a request thread can no longer
  ;; act as web; what it would have handed over is dropped, as the page
  ;; is going away.
  (define (spawn-as-web procedure)
    (guard (c [(and (unloaded? c) (eq? (unloaded-owner c) %self)) #f])
      (call-as-owner %self (lambda () (spawn-task procedure)))))

  (define (post-as-web thunk)
    (spawn-as-web (lambda (restore) (thunk))))

  ;; A quit names the newest of its client's item tasks that has started:
  ;; the items queued behind a busy command, the quit's own among them, are
  ;; not what it stops. The first quit cancels the task, and a second for
  ;; the same task stops it, as a third C-g overrides inhibit-quit in
  ;; Emacs. A task paused for its client's input is left to read the quit
  ;; as input, as Emacs reads C-g as a key while it waits for one;
  ;; cancelling it too would make one key act twice. Request threads and
  ;; the main thread both reach these, under the lock.
  (define (live-tasks-of tasks)
    (filter (lambda (t) (not (eq? (task-state t) 'done))) tasks))

  (define (live-item-tasks c)
    (live-tasks-of (client-item-tasks c)))

  (define (reading-input? c t)
    (and (memq (task-state t) '(paused woken)) (memq t (client-input-readers c)) #t))

  (define (quit-item-task! c)
    (let ([tasks (live-item-tasks c)])
      (client-item-tasks-set! c tasks)
      (let ([t (find (lambda (t) (memq (task-state t) '(running paused woken))) tasks)])
        (when (and t (not (reading-input? c t)))
          (if (eq? t (client-quit-cancelled c))
              (stop-task t)
              (begin
                (client-quit-cancelled-set! c t)
                (cancel-task t 'quit)))))))

  ;; LEFT runs under the lock. A stop and an unload's raise pass every
  ;; handler, so a wind sees the task leave; its after thunk also runs
  ;; each time the loop switches the paused task out, which is no
  ;; leaving. A hold! once the task has left takes nothing, since nothing
  ;; would release it.
  (define (holding c body left)
    (let ([t (current-task)] [hold 'waiting])
      (define (hold!)
        (with-lock
          (when (eq? hold 'waiting)
            (set! hold 'held)
            (client-held-set! c (fx+ (client-held c) 1)))))
      (dynamic-wind
        void
        (lambda () (body hold!))
        (lambda ()
          (unless (and t (memq (task-state t) '(paused woken)))
            (with-lock
              (when (eq? hold 'held) (release-held! c))
              (set! hold 'left)
              (left)))))))

  ;; A reader holds its client from the call of its resume, so a key
  ;; typed after the one it takes acts on what the reader made of it.
  (define (suspend-for-client-input c receiver)
    (let ([t (current-task)])
      (holding c
        (lambda (hold!)
          (with-lock (client-input-readers-set! c (cons t (client-input-readers c))))
          (suspend (lambda (resume) (receiver (lambda (thunk) (resume thunk) (hold!))))))
        (lambda () (client-input-readers-set! c (remq t (client-input-readers c)))))))

  (define (post-item c procedure)
    (let ([t (spawn-as-web procedure)])
      (when t
        (client-item-tasks-set! c (cons t (live-item-tasks c))))))

  (define (enqueue! thunk)
    (set! outbox (cons thunk outbox))
    (condition-signal wake))

  (define (field item name)
    (let ([p (assoc name item)])
      (and p (cdr p))))

  (define (client-with-id id)
    (and (string? id) (hashtable-ref clients-by-id id #f)))

  ;; A client whose page waits for its first screen is drawn too.
  (define (connected-clients)
    (with-lock
      (fold-right (lambda (c cs) (if (memq c cs) cs (add-connected-to c cs))) connected (append opening code-clients))))

  (define (add-connected-to c cs)
    (cond
      [(null? cs) (list c)]
      [(fx< (client-number c) (client-number (car cs))) (cons c cs)]
      [else (cons (car cs) (add-connected-to c (cdr cs)))]))

  ;; Caller holds the lock.
  (define (remove-client! c)
    (client-removed?-set! c #t)
    (let-values ([(ids entries) (hashtable-entries questions)])
      (vector-for-each
        (lambda (id e)
          (when (eq? (car e) c)
            (hashtable-delete! questions id)
            ((cdr e) (lambda () #f))))
        ids entries))
    (hashtable-delete! clients-by-id (client-id c))
    (set! connected (remq c connected))
    (set! opening (remq c opening))
    (set! code-clients (remq c code-clients))
    (let ([stream (client-stream c)])
      (when stream
        (client-stream-set! c #f)
        (enqueue! (lambda () (reload-page stream)))))
    (wake-applied! c))

  ;; Caller holds the lock. A page without a stream applies nothing until
  ;; a later screen, so a closed stream ends the wait too.
  (define (unapplied? c)
    (and (not (client-removed? c)) (client-stream c) (or (client-in-flight c) (client-waiting c)) #t))

  ;; Caller holds the lock.
  (define (wake-applied! c)
    (unless (unapplied? c)
      (let ([waiters (client-applied-waiters c)])
        (client-applied-waiters-set! c '())
        (for-each (lambda (resume) (resume void)) waiters))))

  (define (wait-until-applied c)
    (suspend
      (lambda (resume)
        (unless (with-lock
                  (and (unapplied? c)
                       (begin (client-applied-waiters-set! c (cons resume (client-applied-waiters c))) #t)))
          (resume void)))))

  ;; Caller holds the lock.
  (define (take-question! id c)
    (let ([e (hashtable-ref questions id #f)])
      (and e (eq? (car e) c)
           (begin (hashtable-delete! questions id) (cdr e)))))

  (define (forget-client! c)
    (let ([timer (client-removal-timer c)])
      (when timer
        (client-removal-timer-set! c #f)
        (timers:cancel! timer)))
    (client-removed c))

  (define (reload-page stream)
    (execute-script stream "location.reload()")
    (stream-close! stream))

  ;; Items are posted under the lock, so each client's go in order
  ;; whichever request thread admits them. Only an item not seen before
  ;; quits: a page resends an item whose post failed, though Tuna may have
  ;; received it.
  (define (admit! c seq item)
    (with-lock (admit-held! c seq item)))

  ;; Caller holds the lock.
  (define (admit-held! c seq item)
    (let ([pending (client-pending c)])
      (cond
        [(or (client-removed? c) (fx< seq (client-next c)) (hashtable-contains? pending seq)) #f]
        [else
         (when (eq? (field item "quit") #t)
           (quit-item-task! c))
         (hashtable-set! pending seq item)
         (let loop ()
           (let* ([n (client-next c)] [next (hashtable-ref pending n #f)])
             (when next
               (hashtable-delete! pending n)
               (client-next-set! c (fx+ n 1))
               (set! queued (fx+ queued 1))
               (post-item c (lambda (restore) (run-item c n next restore)))
               (loop))))
         (and (fx>= (hashtable-size pending) max-held-items)
              (begin (remove-client! c) #t))])))

  (define (post-code-input! c item)
    (unless (with-lock
              (and (not (client-removed? c))
                   (begin (admit-held! c (client-next c) item) #t)))
      (assertion-violation 'web:post-input! "a closed client" c)))

  ;; While a command waits for its page's answer, the client's later
  ;; items wait too, so they act on what the command made of the answer.
  ;; A quit waits in its turn: it cancelled the command it stops when it
  ;; was admitted, and running before the items ahead of it would leave
  ;; them to run outside what it quit. An item that arrives while earlier
  ;; ones still wait joins them, since it may run before the task that
  ;; releases them continues.
  (define (run-item c seq item restore)
    (unless (with-lock
              (set! queued (fx- queued 1))
              (and (or (fx> (client-held c) 0) (pair? (client-deferred c)))
                   (begin (client-deferred-set! c (append (client-deferred c) (list (cons seq item)))) #t)))
      (handle-in-order c seq item restore)))

  ;; An item task spawned under the lock by a task starts masked, as the
  ;; lock's holder is, so the handler runs through the task's restore, or
  ;; a quit would wait for the command it is meant to stop.
  (define (handle-in-order c seq item restore)
    (dynamic-wind
      (lambda () (timers:set-idle! #f))
      (lambda ()
        (unless (client-removed? c)
          (client-through-set! c seq)
          (parameterize ([current-client c])
            (restore (lambda () (handle-item c item))))))
      (lambda ()
        (when (with-lock (fx= queued 0))
          (timers:set-idle! #t)))))

  ;; Caller holds the lock.
  (define (release-held! c)
    (client-held-set! c (fx- (client-held c) 1))
    (when (and (fx= (client-held c) 0) (pair? (client-deferred c)))
      (post-deferred! c)))

  ;; Caller holds the lock. Each waiting item runs in a task of its own,
  ;; posted before the one ahead of it runs, so a raise, a quit or a pause
  ;; in one leaves the rest to run, as for items that never waited; one
  ;; that holds them in turn holds the rest again.
  (define (post-deferred! c)
    (set! queued (fx+ queued 1))
    (post-item c
      (lambda (restore)
        (let ([next (with-lock
                      (set! queued (fx- queued 1))
                      (let ([items (client-deferred c)])
                        (and (fx= (client-held c) 0) (pair? items)
                             (begin
                               (client-deferred-set! c (cdr items))
                               (when (pair? (cdr items)) (post-deferred! c))
                               (car items)))))])
          (when next
            (handle-in-order c (car next) (cdr next) restore))))))

  ;; The question goes after the screen the batch draws, so the page
  ;; answers about what the asking command has done so far.
  (define (ask-and-wait c name value)
    (let* ([id (begin (set! last-question (fx+ last-question 1)) last-question)]
           [ask (if (client-code c)
                    (make-code-question id name value)
                    (format "tuna.ask(~a, ~s, ~a)" id name (parameterize ([json-escape-html? #t]) (json->string value))))])
      (holding c
        (lambda (hold!)
          (suspend
            (lambda (resume)
              (hold!)
              (unless (with-lock
                        (and (or (client-code c) (client-stream c)) (not (client-removed? c))
                             (begin
                               (hashtable-set! questions id (cons c resume))
                               (client-asks-set! c (append (client-asks c) (list ask)))
                               #t)))
                (resume (lambda () #f))))))
        (lambda () (hashtable-delete! questions id)))))

  ;; Caller holds the lock.
  (define (send-asks! c)
    (let ([asks (client-asks c)] [stream (client-stream c)])
      (client-asks-set! c '())
      (when stream
        (for-each
          (lambda (script)
            (if (client-waiting c)
                (client-calls-set! c (cons script (client-calls c)))
                (enqueue! (lambda () (execute-script stream script)))))
          asks))))

  (define (answer request)
    (let ([item (guard (e [(json-error? e) #f]) (bytevector->json (request-body request)))])
      (when (pair? item)
        (let ([id (field item "id")] [c (with-lock (client-with-id (field item "client")))])
          (when (and c (fixnum? id))
            (let ([resume (with-lock (take-question! id c))])
              (when resume
                (let ([value (let ([p (assoc "value" item)]) (if p (cdr p) 'null))])
                  (resume (lambda () value)))))))))
    no-content)

  (define (handle-item c item)
    (let* ([type (field item "type")]
           [handler (and (string? type) (tables:ref input-handlers type #f))])
      (cond
        [handler (call-as-owner (tables:owner input-handlers type) (lambda () (handler c item)))]
        [(member type reported-types) (void)]
        [else
         (set! reported-types (cons type reported-types))
         (report (condition (make-warning) (make-who-condition 'web:input-handlers)
                   (make-message-condition (format "no handler for items of type ~s" type))))])))

  (define no-content (response 204 '() ""))

  (define (input request)
    (let ([item (guard (e [(json-error? e) #f]) (bytevector->json (request-body request)))])
      (when (pair? item)
        (let ([seq (field item "seq")] [c (with-lock (client-with-id (field item "client")))])
          (when (and c (fixnum? seq) (fx> seq 0))
            (when (admit! c seq item)
              (post-as-web (lambda () (forget-client! c))))))))
    no-content)

  (define (goodbye request)
    (let ([item (guard (e [(json-error? e) #f]) (bytevector->json (request-body request)))])
      (when (pair? item)
        (let ([c (with-lock
                   (let ([c (client-with-id (field item "client"))])
                     (and c (begin (remove-client! c) c))))])
          (when c
            (post-as-web (lambda () (forget-client! c)))))))
    no-content)

  (define (valid-name? v)
    (and (string? v)
         (fx<= 1 (string-length v) 64)
         (for-all (lambda (c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\-)))
                  (string->list v))))

  (define (usable-upload-entry? entry)
    (define (refuse message irritant)
      (unless (member entry upload-entries)
        (report (condition (make-warning) (make-who-condition 'web:upload-handlers)
                  (make-message-condition message) (make-irritants-condition (list irritant)))))
      #f)
    (cond
      [(not (valid-name? (car entry))) (refuse "not 1 to 64 letters, digits and hyphens" (car entry))]
      [(not (procedure? (cadr entry))) (refuse "not a procedure" (cadr entry))]
      [else #t]))

  (define (refresh-upload-handlers!)
    (let ([entries (table-files upload-handlers)])
      (unless (equal? entries upload-entries)
        (let ([usable (filter usable-upload-entry? entries)])
          (set! upload-entries entries)
          (with-lock (set! uploads usable))))))

  (define upload-failed (response 500 '(("content-type" . "text/plain")) "The upload's handler failed\n"))

  ;; The server's copy of the table keeps an entry until the batch that
  ;; unloads its module ends, so its owner may have begun to unload: the
  ;; name then has no handler. Advice on report may touch editor state, so a
  ;; handler's raise is reported on the main thread, as the handler's
  ;; module's.
  (define (run-upload entry c body)
    (guard (e [(and (unloaded? e) (eq? (unloaded-owner e) (caddr entry))) not-found])
      (call-as-owner (caddr entry)
        (lambda ()
          (guard (e [#t (spawn-task (lambda (restore) (report e))) upload-failed])
            ((cadr entry) c body)
            no-content)))))

  (define (upload request)
    (let* ([parts (request-parts request "/upload/")]
           [entry (and parts (null? (cdr parts))
                       (let ([name (car parts)]) (with-lock (assoc name uploads))))])
      (cond
        [(not entry) not-found]
        [(with-lock (client-with-id (request-header request "tuna-client")))
         => (lambda (c) (run-upload entry c (request-body request)))]
        [else no-content])))

  (define (signal-client request)
    (let ([signals (guard (e [(json-error? e) #f]) (read-signals request))])
      (and (pair? signals) (field signals "client"))))

  (define (screen-element n through content)
    (haml
      (:main ([id "screen"] [data-count n] [data-through through]
              [data-init (post (format "/applied?count=~a" n)) "; el.removeAttribute('data-init')"])
        (raw-html content))))

  ;; Datastar's framing adds 16 bytes, its data prefix and a newline, to
  ;; each line of an event's elements, and about 120 of event name and
  ;; options before them.
  (define (event-size content)
    (let ([n (bytevector-length content)])
      (let loop ([i 0] [lines 1])
        (if (fx= i n)
            (fx+ n 120 (fx* 16 lines))
            (loop (fx+ i 1) (if (fx= (bytevector-u8-ref content i) 10) (fx+ lines 1) lines))))))

  (define (unconfirmed-bytes c)
    (fold-left (lambda (sum e) (fx+ sum (cdr e))) 0 (client-unconfirmed c)))

  ;; The lock's holder may not post, so the report goes by the sender.
  (define (too-large c size)
    (enqueue!
      (lambda ()
        (report-later (condition (make-warning) (make-who-condition 'web)
                                 (make-message-condition "a screen is larger than the stream's limit, so the page keeps the last")
                                 (make-irritants-condition (list (client-id c) size stream-limit)))))))

  (define (stream-failed c)
    (report-later (condition (make-warning) (make-who-condition 'web)
                             (make-message-condition "the stream to a page failed")
                             (make-irritants-condition (list (client-id c))))))

  ;; A screen the stream library cannot hold whole would fail the stream,
  ;; and the page's next stream would be sent the same screen, so it is
  ;; not sent at all. Caller holds the lock.
  (define (dispatch-screen! c content through now)
    (let ([size (event-size content)])
      (client-waiting-set! c #f)
      (if (fx> size stream-limit)
          (begin (too-large c size) (wake-applied! c))
          (let ([n (fx+ (client-count c) 1)] [stream (client-stream c)] [calls (reverse (client-calls c))])
            (client-count-set! c n)
            (client-in-flight-set! c n)
            (client-sent-at-set! c now)
            (client-unconfirmed-set! c (append (client-unconfirmed c) (list (cons n size))))
            (client-calls-set! c '())
            (enqueue!
              (lambda ()
                (unless (or (patch-elements stream (screen-element n through content))
                            (not (with-lock (eq? (client-stream c) stream))))
                  (stream-failed c))
                (for-each (lambda (script) (execute-script stream script)) calls)))))))

  ;; The raise may come inside another plugin's draw or command, so the
  ;; removal hook runs in a task of its own. A cancel is its caller's.
  (define (call-code-page c procedure . arguments)
    (let ([owner (code-page-owner (client-code c))])
      (guard (e [(not (cancelled? e))
                 (unless (and (unloaded? e) (eq? (unloaded-owner e) owner))
                   (report e))
                 (when (with-lock (and (not (client-removed? c)) (begin (remove-client! c) #t)))
                   (post-as-web (lambda () (forget-client! c))))
                 #f])
        (call-as-owner owner (lambda () (apply procedure c arguments))))))

  ;; Values cross to a code page and back as JSON, as they would to a
  ;; browser page, so the code that sent or asked sees none a page could
  ;; not give.
  (define (as-page-would value)
    (string->json (json->string value)))

  ;; A code page applies a screen as it receives it, so none is held back.
  (define (give-code-screen! c screen title)
    (let ([content (if (bytevector? screen) screen (html->bytevector screen))])
      (when (with-lock
              (let ([last (client-last c)])
                (and (not (client-removed? c))
                     (not (and last (bytevector=? content last) (equal? title (client-title c))))
                     (begin (client-last-set! c content) (client-title-set! c title) #t))))
        (call-code-page c (code-page-receive-screen (client-code c)) screen title))
      (let ([asks (with-lock (let ([asks (client-asks c)]) (client-asks-set! c '()) asks))]
            [answer (code-page-answer (client-code c))])
        (for-each
          (lambda (q)
            (let ([resume (with-lock (take-question! (code-question-id q) c))])
              (when resume
                (let ([value (call-code-page c
                               (lambda (client name value) (as-page-would (answer client name value)))
                               (code-question-name q) (as-page-would (code-question-value q)))])
                  (resume (lambda () value))))))
          asks))))

  (define (give-screen! c screen title)
    (if (client-code c)
        (give-code-screen! c screen title)
        (give-page-screen! c screen title)))

  (define (give-page-screen! c screen title)
    (let ([content (if (bytevector? screen) screen (html->bytevector screen))]
          [through (client-through c)]
          [now (real-time)])
      (when (fx>= (fx- now files-checked) 1000)
        (set! files-checked now)
        (check-files!))
      (with-lock
        (let ([last (client-last c)] [stream (client-stream c)])
          (when (memq c opening)
            (client-first-set! c content)
            (client-title-set! c title))
          (when (and stream (not (equal? title (client-title c))))
            (client-title-set! c title)
            (enqueue! (lambda () (patch-elements stream (title-element title)))))
          (when (and stream (not (and last (bytevector=? content last))))
            (client-last-set! c content)
            (if (and (client-in-flight c)
                     (or (fx< (fx- now (client-sent-at c)) confirmation-wait)
                         (fx> (fx+ (unconfirmed-bytes c) (event-size content)) stream-limit)))
                (client-waiting-set! c (cons content through))
                (dispatch-screen! c content through now)))
          (send-asks! c)))))

  (define (applied request)
    (let ([id (signal-client request)]
          [n (let ([query (request-query request)])
               (and query (let ([count (assoc "count" (query->alist query))])
                            (and count (string->number (cdr count))))))])
      (with-lock
        (let ([c (client-with-id id)])
          (when (and c (fixnum? n))
            (client-unconfirmed-set! c (filter (lambda (e) (fx> (car e) n)) (client-unconfirmed c))))
          (when (and c (eqv? n (client-in-flight c)))
            (client-in-flight-set! c #f)
            (let ([waiting (client-waiting c)])
              (when waiting
                (dispatch-screen! c (car waiting) (cdr waiting) (real-time))))
            (wake-applied! c)))))
    no-content)

  (define (call-page c name value)
    (let ([json (parameterize ([json-escape-html? #t]) (json->string value))])
      (if (client-code c)
          (let ([call (lambda ()
                        (unless (with-lock (client-removed? c))
                          (call-code-page c (code-page-receive-call (client-code c)) name (string->json json))))])
            (if (on-main-thread?) (call) (post-as-web call)))
          (let ([script (format "tuna.call(~s, ~a)" name json)])
            (with-lock
              (let ([stream (client-stream c)])
                (when stream
                  (if (client-waiting c)
                      (client-calls-set! c (cons script (client-calls c)))
                      (enqueue! (lambda () (execute-script stream script)))))))))))

  (define (open-stream! c stream)
    (let ([old (client-stream c)])
      (when old
        (enqueue! (lambda () (stream-close! old)))))
    (client-stream-set! c stream)
    (client-last-set! c (let ([first (client-first c)]) (and (bytevector? first) first)))
    (when (eq? (client-first c) 'served)
      (client-title-set! c #f))
    (client-first-set! c 'served)
    (client-in-flight-set! c #f)
    (client-unconfirmed-set! c '())
    (client-waiting-set! c #f)
    (client-calls-set! c '())
    (unless (memq c connected)
      (set! connected (add-connected-to c connected)))
    (sync-head! c)
    (wake-applied! c))

  (define (stream-closed! c stream)
    (when (with-lock
            (and (eq? (client-stream c) stream)
                 (begin
                   (client-stream-set! c #f)
                   (client-waiting-set! c #f)
                   (client-calls-set! c '())
                   (set! connected (remq c connected))
                   (wake-applied! c)
                   #t)))
      (post-as-web (lambda () (schedule-removal! c)))))

  (define (schedule-removal! c)
    (unless (or (client-removed? c) (with-lock (client-stream c)) (client-removal-timer c))
      (client-removal-timer-set! c (timers:run-after removal-seconds (lambda () (expire! c))))))

  (define (stream-opened! c)
    (let ([timer (client-removal-timer c)])
      (when timer
        (client-removal-timer-set! c #f)
        (timers:cancel! timer))))

  (define (expire! c)
    (client-removal-timer-set! c #f)
    (when (with-lock
            (and (not (client-removed? c)) (not (client-stream c))
                 (begin (remove-client! c) #t)))
      (client-removed c)))

  (define (screen request)
    (let ([c (with-lock (client-with-id (signal-client request)))])
      (if c
          (letrec ([stream (make-stream (lambda () (stream-closed! c stream)))])
            (if (with-lock (and (not (client-removed? c)) (begin (open-stream! c stream) #t)))
                (post-as-web (lambda () (stream-opened! c)))
                (reload-page stream))
            (sse-response stream))
          (let ([stream (make-stream)])
            (reload-page stream)
            (sse-response stream)))))

  (define (owner-folder owner)
    (let ([name (owner-name owner)])
      (if (eq? (module-owner name) owner)
          (let-values ([(source object found?)
                        (default-library-search-handler 'web name (library-directories) (library-extensions))])
            (and source (path-parent source)))
          configuration-folder)))

  (define (table-files table)
    (map (lambda (entry) (list (car entry) (cdr entry) (tables:owner table (car entry))))
         (tables:entries table)))

  (define (modification-time path)
    (guard (e [(i/o-error? e) #f])
      (file-modification-time path)))

  (define (file-bytes path)
    (guard (e [(i/o-error? e) #f])
      (let ([bytes (call-with-port (open-file-input-port path) get-bytevector-all)])
        (if (eof-object? bytes) #vu8() bytes))))

  (define (cannot-read who what)
    (report (condition (make-warning) (make-who-condition who)
              (make-message-condition "cannot read the file") (make-irritants-condition (list what)))))

  (define (slot-of kind name)
    (or (hashtable-ref slots (cons kind name) #f)
        (let ([slot (fx+ (hashtable-size slots) 1)])
          (hashtable-set! slots (cons kind name) slot)
          slot)))

  ;; A file that cannot be read stays, without bytes, so that it comes back
  ;; once it can be read.
  (define (read-head-file who slot path old)
    (let* ([time (modification-time path)] [bytes (and time (file-bytes path))])
      (when (and (not bytes) (or (not old) (head-file-bytes old)))
        (cannot-read who path))
      (make-head-file slot path time bytes
        (cond
          [(not old) 1]
          [(equal? bytes (head-file-bytes old)) (head-file-version old)]
          [else (fx+ (head-file-version old) 1)]))))

  (define (read-head-files who kind entries old-entries old-files)
    (let loop ([entries entries] [files '()])
      (if (null? entries)
          (reverse files)
          (let* ([entry (car entries)] [value (cadr entry)]
                 [path (and (string? value)
                            (if (path-absolute? value)
                                value
                                (let ([folder (owner-folder (caddr entry))])
                                  (and folder (string-append folder "/" value)))))])
            (cond
              [path
               (let* ([slot (slot-of kind (car entry))]
                      [old (find (lambda (f) (fx= (head-file-slot f) slot)) old-files)])
                 (loop (cdr entries)
                       (cons (read-head-file who slot path (and old (string=? (head-file-path old) path) old))
                             files)))]
              [else
               (unless (member entry old-entries)
                 (cannot-read who value))
               (loop (cdr entries) files)])))))

  (define (href f)
    (format "/files/~a/~a?v=~a" (head-file-slot f) (percent-encode (path-last (head-file-path f)))
      (head-file-version f)))

  (define (refresh-head-files!)
    (let ([styles (table-files stylesheets)] [modules (table-files scripts)] [earlies (table-files early-scripts)])
      (unless (and (equal? styles stylesheet-entries) (equal? modules script-entries) (equal? earlies early-entries))
        (let ([new-styles (read-head-files 'web:stylesheets 'stylesheet styles stylesheet-entries stylesheet-files)]
              [new-modules (read-head-files 'web:scripts 'script modules script-entries script-files)]
              [new-earlies (read-head-files 'web:early-scripts 'early-script earlies early-entries early-files)])
          (set! stylesheet-entries styles)
          (set! script-entries modules)
          (set! early-entries earlies)
          (update-head! new-styles new-modules new-earlies)))))

  (define (check-files!)
    (define (check who)
      (lambda (f)
        (if (equal? (modification-time (head-file-path f)) (head-file-time f))
            f
            (read-head-file who (head-file-slot f) (head-file-path f) f))))
    (let ([styles (map (check 'web:stylesheets) stylesheet-files)]
          [modules (map (check 'web:scripts) script-files)]
          [earlies (map (check 'web:early-scripts) early-files)])
      (unless (and (for-all eq? styles stylesheet-files) (for-all eq? modules script-files) (for-all eq? earlies early-files))
        (update-head! styles modules earlies))))

  ;; A page runs its scripts once, so one whose scripts or early scripts
  ;; changed reloads.
  (define (update-head! styles modules earlies)
    (let ([new-links (map (lambda (f) (cons (head-file-slot f) (href f))) (filter head-file-bytes styles))]
          [new-hrefs (map href (filter head-file-bytes modules))]
          [new-early (map href (filter head-file-bytes earlies))])
      (with-lock
        (set! stylesheet-files styles)
        (set! script-files modules)
        (set! early-files earlies)
        (set! links new-links)
        (unless (and (equal? new-hrefs script-hrefs) (equal? new-early early-hrefs))
          (set! script-hrefs new-hrefs)
          (set! early-hrefs new-early)
          (set! scripts-version (fx+ scripts-version 1)))
        (for-each sync-head! connected))))

  ;; Caller holds the lock. A browser cannot unload a module it has run,
  ;; so a page whose scripts changed reloads. Its stream closes then, so
  ;; the client is disconnected at once, as when a stream closes: a screen
  ;; given meanwhile would fail on the closed stream.
  (define (sync-head! c)
    (let ([stream (client-stream c)])
      (cond
        [(not (fx= (client-scripts-version c) scripts-version))
         (client-scripts-version-set! c scripts-version)
         (client-links-set! c links)
         (client-stream-set! c #f)
         (client-waiting-set! c #f)
         (client-calls-set! c '())
         (set! connected (remq c connected))
         (wake-applied! c)
         (enqueue! (lambda () (reload-page stream) (post-as-web (lambda () (schedule-removal! c)))))]
        [(not (eq? (client-links c) links))
         (let ([old (client-links c)] [new links])
           (client-links-set! c new)
           (enqueue! (lambda () (patch-links stream old new))))])))

  (define (title-element text)
    (haml (:title ([id "tuna-title"]) text)))

  (define (link-element link)
    (haml (:link ([id "tuna-stylesheet-" (car link)] [rel "stylesheet"] [href (cdr link)]))))

  (define append-to-head (patch-elements-options [selector "head"] [mode (patch-mode append)]))

  (define (patch-links stream old new)
    (for-each
      (lambda (link)
        (unless (assv (car link) new)
          (patch-elements stream #f
            (patch-elements-options [selector (format "#tuna-stylesheet-~a" (car link))]
                                    [mode (patch-mode remove)]))))
      old)
    (for-each
      (lambda (link)
        (let ([had (assv (car link) old)])
          (cond
            [(not had) (patch-elements stream (link-element link) append-to-head)]
            [(not (string=? (cdr had) (cdr link))) (patch-elements stream (link-element link))])))
      new))

  (define content-types
    '(("css" . "text/css; charset=utf-8") ("js" . "text/javascript; charset=utf-8")
      ("mjs" . "text/javascript; charset=utf-8") ("json" . "application/json")
      ("html" . "text/html; charset=utf-8") ("txt" . "text/plain; charset=utf-8")
      ("svg" . "image/svg+xml") ("png" . "image/png") ("jpg" . "image/jpeg")
      ("jpeg" . "image/jpeg") ("gif" . "image/gif") ("webp" . "image/webp")
      ("ico" . "image/x-icon") ("woff" . "font/woff") ("woff2" . "font/woff2")
      ("ttf" . "font/ttf") ("otf" . "font/otf") ("wasm" . "application/wasm")))

  (define (content-type path)
    (let ([type (assoc (string-downcase (path-extension path)) content-types)])
      (if type (cdr type) "application/octet-stream")))

  (define not-found (response 404 '(("content-type" . "text/plain")) "Not found\n"))

  (define (file-response path bytes)
    (if bytes
        (response 200 (list (cons "content-type" (content-type path)) '("cache-control" . "no-cache"))
          bytes)
        not-found))

  (define (split-path path)
    (let loop ([i (fx- (string-length path) 1)] [end (string-length path)] [parts '()])
      (cond
        [(fx< i 0) (cons (substring path 0 end) parts)]
        [(char=? (string-ref path i) #\/) (loop (fx- i 1) i (cons (substring path (fx+ i 1) end) parts))]
        [else (loop (fx- i 1) end parts)])))

  (define (relative-path parts)
    (and (pair? parts)
         (for-all (lambda (part)
                    (not (or (member part '("" "." ".."))
                             (exists (lambda (c) (char=? c #\nul)) (string->list part)))))
                  parts)
         (fold-left (lambda (path part) (string-append path "/" part)) (car parts) (cdr parts))))

  (define (request-parts request prefix)
    (let ([path (percent-decode (request-path request))])
      (and (fx>= (string-length path) (string-length prefix))
           (string=? (substring path 0 (string-length prefix)) prefix)
           (split-path (substring path (string-length prefix) (string-length path))))))

  (define page-folder (string-append (owner-folder %self) "/web/page"))

  (define (page-file request)
    (let ([file (relative-path (request-parts request "/web/"))])
      (if file
          (let ([path (string-append page-folder "/" file)])
            (file-response path (file-bytes path)))
          not-found)))

  (define (served-file request)
    (let ([parts (request-parts request "/files/")])
      (let ([slot (and parts (pair? (cdr parts)) (string->number (car parts)))]
            [file (and parts (relative-path (cdr parts)))])
        (let ([f (and slot file
                      (with-lock
                        (find (lambda (f) (eqv? (head-file-slot f) slot))
                              (append stylesheet-files script-files early-files))))])
          (cond
            [(not f) not-found]
            [(string=? file (path-last (head-file-path f))) (file-response file (head-file-bytes f))]
            [else
             (let ([path (string-append (path-parent (head-file-path f)) "/" file)])
               (file-response path (file-bytes path)))])))))

  (define (random-id)
    (let ([bytes (call-with-port (open-file-input-port "/dev/urandom")
                   (lambda (p) (get-bytevector-n p 16)))])
      (apply string-append (map (lambda (b) (format "~(~2,'0x~)" b)) (bytevector->u8-list bytes)))))

  ;; A stream can end without an error, as when the server stops or gives
  ;; up on a stream that fell behind, and Datastar opens such a stream again
  ;; only when told to retry always.
  (define screen-action
    (get "/screen" (fetch-options [retry (fetch-retry always)] [retry-max-count 1000000000])))

  ;; The first screen comes inside the page, so the browser paints no
  ;; empty frame before it, and the early scripts can place it before the
  ;; first paint: a module would run after it.
  (define (shell id title-text styles modules early first)
    (haml
      (:html ([lang "en"])
        (:head
          (:meta ([charset "utf-8"]))
          (:meta ([name "viewport"] [content "width=device-width, initial-scale=1"]))
          (:meta ([name "color-scheme"] [content "light dark"]))
          (title-element title-text)
          (:script ([type "importmap"]) "{\"imports\":{\"datastar\":\"/web/datastar.js\",\"tuna\":\"/web/tuna.js\"}}")
          (:script ([type "module"] [src "/web/datastar.js"]))
          (:script ([type "module"] [src "/web/tuna.js"]))
          (map link-element styles)
          (map (lambda (src) (haml (:script ([type "module"] [src src])))) modules)
          (map (lambda (src) (haml (:script ([src src])))) early))
        (:body ([data-signals:client "'" id "'"] [data-init screen-action])
          (:main ([id "screen"]) (when first (raw-html first)))
          (:script "document.dispatchEvent(new Event(\"tuna-first-screen\"))")))))

  (define page-headers
    '(("content-type" . "text/html; charset=utf-8") ("cache-control" . "no-store")))

  (define first-screen-wait 10)

  ;; The page waits for the batch that adds its client, whose end draws
  ;; it: what batch-ended posts runs in the next batch, so its release
  ;; runs once every client is drawn.
  (define (page request)
    (if (string=? (request-path request) "/")
        (let* ([id (random-id)]
               [c (with-lock
                    (set! added (fx+ added 1))
                    (let ([c (make-client id added #f links scripts-version)])
                      (hashtable-set! clients-by-id id c)
                      (set! opening (cons c opening))
                      c))])
          (post-as-web (lambda () (schedule-removal! c) (set! added-now (cons c added-now)) (client-added c)))
          (let-values ([(first title modules early)
                        (with-mutex lock
                          (let ([deadline (add-duration (current-time 'time-utc) (make-time 'time-duration 0 first-screen-wait))])
                            (let wait ()
                              (when (and (memq c opening) (time<? (current-time 'time-utc) deadline))
                                (condition-wait first-screens lock deadline)
                                (wait))))
                          (set! opening (remq c opening))
                          (values (let ([first (client-first c)]) (and (bytevector? first) first)) (client-title c)
                                  script-hrefs early-hrefs))])
            (response 200 page-headers
              (html->bytevector (shell id title (client-links c) modules early first)))))
        not-found))

  (define forbidden (response 403 '(("content-type" . "text/plain")) "Forbidden\n"))

  ;; Whoever reaches 127.0.0.1 is on this machine, which Tuna trusts; a
  ;; peer at another address may be anyone on that network, such as a
  ;; proxy's, so it passes only with the proxy's secret. A web page from
  ;; elsewhere may send a request to the port, but its browser names that
  ;; page's origin.
  (define (allowed? request)
    (let* ([state (with-lock (cons allowed proxy-secret))]
           [names (car state)]
           [host (request-authority request)]
           [origin (request-header request "origin")])
      (and (or (member (request-client-address request) '("127.0.0.1" "::1"))
               (let ([given (request-header request "tuna-proxy-secret")] [secret (cdr state)])
                 (and given secret (secret=? (string->utf8 given) secret))))
           host
           (member (string-downcase host) names)
           (or (not origin)
               (let ([origin (string-downcase origin)])
                 (exists (lambda (name)
                           (or (string=? origin (string-append "http://" name))
                               (string=? origin (string-append "https://" name))))
                         names))))))

  ;; Every byte is compared whatever the first difference, so the time
  ;; taken does not tell a guesser how much of the secret was right.
  (define (secret=? a b)
    (and (fx= (bytevector-length a) (bytevector-length b))
         (let loop ([i 0] [difference 0])
           (if (fx= i (bytevector-length a))
               (fx= difference 0)
               (loop (fx+ i 1)
                     (fxlogor difference (fxlogxor (bytevector-u8-ref a i) (bytevector-u8-ref b i))))))))

  (define (checked handle)
    (handler (lambda (request) (if (allowed? request) (handle request) forbidden))))

  (define (allow-hosts!) (allow-port! listening-port))

  (define (allow-port! p)
    (let ([names (append (if p (list (format "127.0.0.1:~a" p) (format "localhost:~a" p)) '())
                         (map string-downcase (hosts)))])
      (with-lock (set! allowed names))))

  (define (report-later e)
    (post-as-web (lambda () (report e))))

  (define heartbeat (string->utf8 ":\n\n"))

  (define (heartbeat-after t)
    (add-duration t (make-time 'time-duration 0 heartbeat-seconds)))

  ;; Once a stream's response has begun, only this thread writes to it, in
  ;; the order queued: a cancel can split the stream library's own lock when
  ;; its code runs on the main thread. H2O ends a response that writes
  ;; nothing for its I/O timeout, and so may a proxy between, so every page
  ;; gets a comment on a fixed period: a period that any write restarted
  ;; would let a busy page starve an idle one.
  (define (send-loop me)
    (let loop ([next (heartbeat-after (current-time 'time-utc))])
      (let-values ([(work next)
                    (with-mutex lock
                      (let wait ()
                        (let ([now (current-time 'time-utc)])
                          (cond
                            [(not (eq? sender me)) (values #f next)]
                            [(time<=? next now)
                             (values (map (lambda (c)
                                            (let ([stream (client-stream c)])
                                              (lambda () (stream-send! stream heartbeat))))
                                          connected)
                                     (heartbeat-after now))]
                            [(pair? outbox)
                             (let ([work (reverse outbox)])
                               (set! outbox '())
                               (values work next))]
                            [else (condition-wait wake lock next) (wait)]))))])
        (when work
          (for-each (lambda (send) (guard (e [#t (report-later e)]) (send))) work)
          (loop next)))))

  (define (proxy-problem message path)
    (report (condition (make-warning) (make-who-condition 'web:proxy-secret-file)
              (make-message-condition message) (make-irritants-condition (list path)))))

  (define (home-path? path)
    (and (fx>= (string-length path) 2) (string=? (substring path 0 2) "~/")))

  ;; The file's text is never put in a report, which may be logged.
  (define (read-proxy-secret path)
    (let ([file (if (home-path? path)
                    (string-append (getenv "HOME") (substring path 1 (string-length path)))
                    path)])
      (guard (e [(i/o-error? e) (proxy-problem "cannot read the file" path) #f])
        (cond
          [(not (fx= 0 (fxand (get-mode file) #o077)))
           (proxy-problem "other users can open the file; make its mode 600" path)
           #f]
          [else
           (let* ([text (call-with-port (open-input-file file) get-string-all)]
                  [text (if (eof-object? text) "" text)]
                  [end (let trim ([end (string-length text)])
                         (if (and (fx> end 0) (memv (string-ref text (fx- end 1)) '(#\newline #\return)))
                             (trim (fx- end 1))
                             end))])
             (if (fx< end 16)
                 (begin (proxy-problem "the secret is shorter than 16 characters" path) #f)
                 (string->utf8 (substring text 0 end))))]))))

  (define (proxy-address)
    (let* ([address (listen-also)] [file (proxy-secret-file)] [secret (and file (read-proxy-secret file))])
      (with-lock (set! proxy-secret secret))
      (when (and address (not file))
        (report (condition (make-warning) (make-who-condition 'web:listen-also)
                  (make-message-condition "web:proxy-secret-file is not set, so only 127.0.0.1 is listened on"))))
      (and secret address)))

  ;; The names are allowed before the port is listened on, so the first
  ;; request finds them.
  (define (listen p addresses)
    (allow-port! p)
    (start-server
      (map (lambda (address) (http-listener address p)) addresses)
      (list (make-host (list (format "127.0.0.1:~a" p))
              ;; Each screen repeats most of the one before. Brotli finds it
              ;; from quality 2 and gains little past 5; zstd from 9 keeps a
              ;; 4 MB window, which avoided the occasional near-whole screen
              ;; lower levels sent; gzip's 32 KB window never reaches it, so
              ;; gzip stays at its fastest.
              (list (route "/screen" (checked screen)
                      (compress (encodings zstd br gzip) (qualities [zstd 9] [br 5] [gzip 1])))
                    (route "/input" (checked input))
                    (route "/applied" (checked applied))
                    (route "/answer" (checked answer))
                    (route "/upload/" (checked upload))
                    (route "/goodbye" (checked goodbye))
                    (route "/web/" (checked page-file))
                    (route "/files/" (checked served-file))
                    (route "/" (checked page)))))
      (server-options [on-error report-later]
                      [max-stream-buffer stream-limit]
                      [http1-request-io-timeout (* 4 heartbeat-seconds 1000)])))

  (define (current-settings) (list (port) (listen-also) (proxy-secret-file)))

  ;; An address that cannot be listened on, such as a proxy network not up
  ;; yet, leaves Tuna on 127.0.0.1 rather than nowhere; it is reported
  ;; only then, since a port in use fails both.
  (define (listen-at p also)
    (if also
        (guard (e [(not (cancelled? e))
                   (let ([s (listen p '("127.0.0.1"))])
                     (report e)
                     s)])
          (listen p (list "127.0.0.1" also)))
        (listen p '("127.0.0.1"))))

  ;; A bind fails at once on a port another process holds, so Tunas that
  ;; start together each get a port of their own.
  (define (listen-free also)
    (let loop ([p first-free-port])
      (let ([s (guard (e [(and (error? e) (fx< p 65535)) #f]) (listen-at p also))])
        (if s (values s p) (loop (fx+ p 1))))))

  (define (start-server!)
    (set! started? #t)
    (let ([also (proxy-address)] [me (list 'sender)])
      (let-values ([(s p) (if (port) (values (listen-at (port) also) (port)) (listen-free also))])
        (set! server s)
        (set! listening-port p))
      (set! server-settings (current-settings))
      (with-lock (set! sender me))
      (fork-task (lambda (restore) (send-loop me)))
      (printf "Tuna is at ~a\n" (listening-url))
      (flush-output-port (current-output-port))))

  (define (stop-server!)
    (with-lock
      (set! sender #f)
      (condition-broadcast wake))
    (let ([s server])
      (set! server #f)
      (set! listening-port #f)
      (when s (server-stop! s))))

  ;; Taking back a setting, as at exit or when the configuration is
  ;; evaluated again, changes the port too, so the server moves only once
  ;; the code running now has finished, and only if a setting is new.
  (define (restart-server!)
    (when started?
      (call-as-owner %self
        (lambda ()
          (spawn-task
            (lambda (restore)
              (let ([now (current-settings)])
                (cond
                  [(and server (equal? server-settings now)) (void)]
                  ;; Listening again would close the pages' streams, and
                  ;; another process could take the port in between.
                  [(and server (eqv? (car now) listening-port) (equal? (cdr server-settings) (cdr now)))
                   (set! server-settings now)]
                  [else (stop-server!) (start-server!)]))))))))

  ;; Started after the batch the plugin loads in, so that what that batch
  ;; posted runs first, such as settings from the command line, whichever
  ;; plugin loaded first.
  (define (post-start!)
    (unless start-posted?
      (set! start-posted? #t)
      (post-as-web start-server!)))

  ;; Only the main thread uses this list.
  (define added-now '())

  (define (release-first-screens!)
    (for-each
      (lambda (c) (post-as-web (lambda () (with-lock (set! opening (remq c opening)) (condition-broadcast first-screens)))))
      added-now)
    (set! added-now '()))

  ;; A code page's client is in no table a request reads, so no request
  ;; can reach it.
  (define (open-code-client! receive-screen receive-call answer)
    (let ([c (with-lock
               (set! added (fx+ added 1))
               (let ([c (make-client (format "code-~a" added) added
                          (make-code-page receive-screen receive-call answer (current-owner)) '() 0)])
                 (set! code-clients (cons c code-clients))
                 c))])
      (client-added c)
      c))

  (define (close-code-client! c)
    (when (with-lock (and (not (client-removed? c)) (begin (remove-client! c) #t)))
      (forget-client! c)))

  (define (close-owner-clients! owner)
    (for-each close-code-client!
      (with-lock (filter (lambda (c) (eq? (code-page-owner (client-code c)) owner)) code-clients))))

  (define (listening-url)
    (and listening-port (format "http://127.0.0.1:~a/" listening-port)))

  (record-writer (record-type-descriptor client)
    (lambda (c p wr) (fprintf p "#<client ~a>" (client-number c)))))

(import %internals)

(options:define-option port #f (lambda (v) (or (not v) (and (fixnum? v) (fx<= 1 v 65535))))
  "The port Tuna listens on, on 127.0.0.1 and on web:listen-also; #f for 7337 or the next free port above it."
  (lambda (v) (restart-server!)))

(options:define-option hosts '() (lambda (v) (and (list? v) (for-all string? v)))
  "Host names, as a Host header gives them, that reach the port besides 127.0.0.1 and localhost."
  (lambda (v) (allow-hosts!)))

(options:define-option listen-also #f (lambda (v) (or (not v) (string? v)))
  "A second numeric address the port is listened on, for a reverse proxy; needs web:proxy-secret-file."
  (lambda (v) (restart-server!)))

(options:define-option proxy-secret-file #f
  ;; Chez counts ~user/ as absolute too, but only ~/ is expanded here.
  (lambda (v)
    (or (not v)
        (and (string? v) (path-absolute? v)
             (or (home-path? v) (not (char=? (string-ref v 0) #\~))))))
  "The file, of mode 600, whose text a request from a peer other than 127.0.0.1 or ::1 must give as Tuna-Proxy-Secret."
  (lambda (v) (restart-server!)))

(hooks:define-hook client-added "Called with a client when its page is served or it is opened.")

(hooks:define-hook client-removed "Called with a client that has been removed.")

(tables:define-table input-handlers "Maps an item's type to a procedure of the client and the item.")

(tables:define-table upload-handlers
  "Maps a name to a procedure of a client and a bytevector, called on a server thread with the body of each upload to /upload/NAME.")

(tables:define-table stylesheets "Maps a name to a CSS file that every page links.")

(tables:define-table scripts "Maps a name to a JavaScript module that every page loads.")

(tables:define-table early-scripts
  "Maps a name to a classic script that every page runs in its head, before the first screen is painted.")

(define current-client
  (make-thread-parameter #f
    (lambda (v)
      (unless (or (not v) (client-record? v))
        (assertion-violation 'web:current-client "not a client or #f" v))
      v)))

(define (suspend-for-input receiver)
  (unless (procedure? receiver)
    (assertion-violation 'web:suspend-for-input "not a procedure" receiver))
  (let ([c (current-client)])
    (if c (suspend-for-client-input c receiver) (suspend receiver))))

(define (clients) (connected-clients))

(define (client? v) (client-record? v))

(define (send-screen! client screen title)
  (unless (client-record? client)
    (assertion-violation 'web:send-screen! "not a client" client))
  (unless (or (html? screen) (bytevector? screen))
    (assertion-violation 'web:send-screen! "not html or a bytevector" screen))
  (unless (string? title)
    (assertion-violation 'web:send-screen! "not a string" title))
  (give-screen! client screen title))

(define (call-page! client name value)
  (unless (client-record? client)
    (assertion-violation 'web:call-page! "not a client" client))
  (unless (valid-name? name)
    (assertion-violation 'web:call-page! "not 1 to 64 letters, digits and hyphens" name))
  (guard (e [(json-error? e) (assertion-violation 'web:call-page! "(json) cannot write it" value)])
    (call-page client name value)))

(define (ask-page client name value)
  (unless (client-record? client)
    (assertion-violation 'web:ask-page "not a client" client))
  (unless (and (string? name)
               (fx<= 1 (string-length name) 64)
               (for-all (lambda (c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\-)))
                        (string->list name)))
    (assertion-violation 'web:ask-page "not 1 to 64 letters, digits and hyphens" name))
  (guard (e [(json-error? e) (assertion-violation 'web:ask-page "(json) cannot write it" value)])
    (json->string value))
  (ask-and-wait client name value))

(define (open-client receive-screen receive-call answer)
  (unless (on-main-thread?)
    (assertion-violation 'web:open-client "not on the main thread"))
  (for-each
    (lambda (v)
      (unless (procedure? v)
        (assertion-violation 'web:open-client "not a procedure" v)))
    (list receive-screen receive-call answer))
  (open-code-client! receive-screen receive-call answer))

(define (post-input! client item)
  (unless (code-client? client)
    (assertion-violation 'web:post-input! "not a client web:open-client opened" client))
  (unless (and (list? item) (for-all (lambda (p) (and (pair? p) (string? (car p)))) item))
    (assertion-violation 'web:post-input! "not an item" item))
  (post-code-input! client
    (guard (e [(json-error? e) (assertion-violation 'web:post-input! "(json) cannot write it" item)])
      (as-page-would item))))

(define (close-client! client)
  (unless (code-client? client)
    (assertion-violation 'web:close-client! "not a client web:open-client opened" client))
  (unless (on-main-thread?)
    (assertion-violation 'web:close-client! "not on the main thread"))
  (close-code-client! client))

(define (wait-for-applied client)
  (unless (client-record? client)
    (assertion-violation 'web:wait-for-applied "not a client" client))
  (wait-until-applied client))

(define (url) (listening-url))

(advice-add! owner-unloading
  (lambda (next owner)
    (next owner)
    (close-owner-clients! owner)))

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (post-start!)
    (release-first-screens!)
    (refresh-head-files!)
    (refresh-upload-handlers!)))

(on-unload stop-server!)
