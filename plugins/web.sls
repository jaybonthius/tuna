#!tuna
(import (h2o) (datastar) (json) (haml))

;; The server's threads run this code, so none of it may be a top-level
;; definition, which can change under a running thread.
(module %internals
  (client-record? client-record-device connected-clients give-screen! call-page start-server! restart-server!
   stop-server! allow-hosts! retitle! refresh-head-files! post-start! release-first-screens! home-path?)

  (define main-thread (get-thread-id))
  (define lock (make-mutex))
  (define wake (make-condition))

  ;; A quit can land anywhere in code on the main thread, and one inside
  ;; the lock would leave a client half changed, so the main thread holds
  ;; the lock only with interrupts disabled. A blocked acquire with
  ;; interrupts disabled would keep a collection waiting for the main
  ;; thread, so it only tries the lock, which other threads hold for a few
  ;; instructions at a time; a body the main thread runs must not raise,
  ;; wait or post.
  (define-syntax with-lock
    (syntax-rules ()
      [(_ e1 e2 ...)
       (if (eqv? (get-thread-id) main-thread)
           (let retry ()
             (let ([v (with-interrupts-disabled
                        (if (mutex-acquire lock #f)
                            (let ([v (let () e1 e2 ...)])
                              (mutex-release lock)
                              v)
                            busy))])
               (if (eq? v busy) (retry) v)))
           (with-mutex lock e1 e2 ...))]))

  (define busy (list 'busy))

  ;; Only the main thread uses through and removal-timer; the lock guards
  ;; the other mutable fields.
  ;; FIRST is the screen the page carries: #f until a batch draws one,
  ;; and the symbol served once the page has gone with it.
  (define-record-type (client make-client client-record?)
    (sealed #t)
    (fields id number (immutable device client-record-device) pending (mutable next) (mutable removed?) (mutable stream)
            (mutable through) (mutable removal-timer)
            (mutable last) (mutable count) (mutable in-flight) (mutable sent-at)
            (mutable waiting) (mutable calls) (mutable links) (mutable scripts-version) (mutable title) (mutable first))
    (protocol
      (lambda (new)
        (lambda (id number device links scripts-version title)
          (new id number device (make-eqv-hashtable) 1 #f #f 0 #f #f 0 #f 0 #f '() links scripts-version title #f)))))

  (define-record-type head-file
    (sealed #t)
    (fields slot path time bytes version))

  (define configuration-folder (string-append (getenv "HOME") "/.config/tuna"))

  (define clients-by-id (make-hashtable string-hash string=?))
  (define connected '())
  (define opening '())
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
  (define scripts-version 0)
  (define page-title #f)
  (define files-checked 0)

  (define max-held-items 10000)
  (define confirmation-wait 1000)
  (define removal-seconds 3600)
  (define heartbeat-seconds 15)

  (define (post-as-web thunk)
    (as-module (this-module) (post! thunk)))

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
    (with-lock (fold-right (lambda (c cs) (if (memq c cs) cs (add-connected-to c cs))) connected opening)))

  (define (add-connected-to c cs)
    (cond
      [(null? cs) (list c)]
      [(fx< (client-number c) (client-number (car cs))) (cons c cs)]
      [else (cons (car cs) (add-connected-to c (cdr cs)))]))

  ;; Caller holds the lock.
  (define (remove-client! c)
    (client-removed?-set! c #t)
    (hashtable-delete! clients-by-id (client-id c))
    (set! connected (remq c connected))
    (set! opening (remq c opening))
    (let ([stream (client-stream c)])
      (when stream
        (client-stream-set! c #f)
        (enqueue! (lambda () (reload-page stream))))))

  (define (forget-client! c)
    (let ([timer (client-removal-timer c)])
      (when timer
        (client-removal-timer-set! c #f)
        (cancel-timer! timer)))
    (client-removed c))

  (define (reload-page stream)
    (execute-script stream "location.reload()")
    (stream-close! stream))

  ;; Items are posted under the lock, so each client's go in order
  ;; whichever request thread admits them. Only an item not seen before
  ;; quits: a page resends an item whose post failed, though Tuna may have
  ;; received it.
  (define (admit! c seq item)
    (with-lock
      (let ([pending (client-pending c)])
        (cond
          [(or (client-removed? c) (fx< seq (client-next c)) (hashtable-contains? pending seq)) #f]
          [else
           (when (eq? (field item "quit") #t)
             (request-quit!))
           (hashtable-set! pending seq item)
           (let loop ()
             (let* ([n (client-next c)] [next (hashtable-ref pending n #f)])
               (when next
                 (hashtable-delete! pending n)
                 (client-next-set! c (fx+ n 1))
                 (set! queued (fx+ queued 1))
                 (post-as-web (lambda () (run-item c n next)))
                 (loop))))
           (and (fx>= (hashtable-size pending) max-held-items)
                (begin (remove-client! c) #t))]))))

  (define (run-item c seq item)
    (with-lock (set! queued (fx- queued 1)))
    (dynamic-wind
      (lambda () (set-idle! #f))
      (lambda ()
        (unless (client-removed? c)
          (client-through-set! c seq)
          (parameterize ([current-client c])
            (handle-item c item))))
      (lambda ()
        (when (with-lock (fx= queued 0))
          (set-idle! #t)))))

  (define (handle-item c item)
    (let* ([type (field item "type")]
           [handler (and (string? type) (table-ref input-handlers type #f))])
      (cond
        [handler (as-module (table-owner input-handlers type) (handler c item))]
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

  (define (signal-client request)
    (let ([signals (guard (e [(json-error? e) #f]) (read-signals request))])
      (and (pair? signals) (field signals "client"))))

  (define (screen-element n through content)
    (haml
      (:main ([id "screen"] [data-count n] [data-through through]
              [data-init (post (format "/applied?count=~a" n)) "; el.removeAttribute('data-init')"])
        (raw-html content))))

  ;; Caller holds the lock.
  (define (dispatch-screen! c content through now)
    (let ([n (fx+ (client-count c) 1)] [stream (client-stream c)] [calls (reverse (client-calls c))])
      (client-count-set! c n)
      (client-in-flight-set! c n)
      (client-sent-at-set! c now)
      (client-waiting-set! c #f)
      (client-calls-set! c '())
      (enqueue!
        (lambda ()
          (patch-elements stream (screen-element n through content))
          (for-each (lambda (script) (execute-script stream script)) calls)))))

  (define (give-screen! c screen)
    (let ([content (if (bytevector? screen) screen (html->bytevector screen))]
          [through (client-through c)]
          [now (real-time)])
      (when (fx>= (fx- now files-checked) 1000)
        (set! files-checked now)
        (check-files!))
      (with-lock
        (let ([last (client-last c)])
          (when (memq c opening)
            (client-first-set! c content))
          (when (and (client-stream c) (not (and last (bytevector=? content last))))
            (client-last-set! c content)
            (if (and (client-in-flight c) (fx< (fx- now (client-sent-at c)) confirmation-wait))
                (client-waiting-set! c (cons content through))
                (dispatch-screen! c content through now)))))))

  (define (applied request)
    (let ([id (signal-client request)]
          [n (let ([query (request-query request)])
               (and query (let ([count (assoc "count" (query->alist query))])
                            (and count (string->number (cdr count))))))])
      (with-lock
        (let ([c (client-with-id id)])
          (when (and c (eqv? n (client-in-flight c)))
            (client-in-flight-set! c #f)
            (let ([waiting (client-waiting c)])
              (when waiting
                (dispatch-screen! c (car waiting) (cdr waiting) (real-time))))))))
    no-content)

  (define (call-page c name value)
    (let ([script (format "tuna.call(~s, ~a)" name
                    (parameterize ([json-escape-html? #t]) (json->string value)))])
      (with-lock
        (let ([stream (client-stream c)])
          (when stream
            (if (client-waiting c)
                (client-calls-set! c (cons script (client-calls c)))
                (enqueue! (lambda () (execute-script stream script)))))))))

  (define (open-stream! c stream)
    (let ([old (client-stream c)])
      (when old
        (enqueue! (lambda () (stream-close! old)))))
    (client-stream-set! c stream)
    (client-last-set! c (let ([first (client-first c)]) (and (bytevector? first) first)))
    (client-first-set! c 'served)
    (client-in-flight-set! c #f)
    (client-waiting-set! c #f)
    (client-calls-set! c '())
    (unless (memq c connected)
      (set! connected (add-connected-to c connected)))
    (sync-head! c))

  (define (stream-closed! c stream)
    (when (with-lock
            (and (eq? (client-stream c) stream)
                 (begin
                   (client-stream-set! c #f)
                   (client-waiting-set! c #f)
                   (client-calls-set! c '())
                   (set! connected (remq c connected))
                   #t)))
      (post-as-web (lambda () (schedule-removal! c)))))

  (define (schedule-removal! c)
    (unless (or (client-removed? c) (with-lock (client-stream c)) (client-removal-timer c))
      (client-removal-timer-set! c (run-with-timer removal-seconds (lambda () (expire! c))))))

  (define (stream-opened! c)
    (let ([timer (client-removal-timer c)])
      (when timer
        (client-removal-timer-set! c #f)
        (cancel-timer! timer))))

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
    (if (member owner '((init) (repl)))
        configuration-folder
        (let-values ([(source object found?)
                      ((library-search-handler) 'web owner (library-directories) (library-extensions))])
          (and source (path-parent source)))))

  (define (table-files table)
    (map (lambda (entry) (list (car entry) (cdr entry) (table-owner table (car entry))))
         (table-entries table)))

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
  ;; so a page whose scripts changed reloads.
  (define (sync-head! c)
    (let ([stream (client-stream c)])
      (cond
        [(not (fx= (client-scripts-version c) scripts-version))
         (client-scripts-version-set! c scripts-version)
         (client-links-set! c links)
         (client-title-set! c page-title)
         (enqueue! (lambda () (reload-page stream)))]
        [else
         (unless (eq? (client-links c) links)
           (let ([old (client-links c)] [new links])
             (client-links-set! c new)
             (enqueue! (lambda () (patch-links stream old new)))))
         (unless (string=? (client-title c) page-title)
           (let ([new page-title])
             (client-title-set! c new)
             (enqueue! (lambda () (patch-elements stream (title-element new))))))])))

  (define (title-element text)
    (haml (:title ([id "tuna-title"]) text)))

  (define (retitle!)
    (let ([new (parameterize ([current-scope #f]) (title))])
      (with-lock
        (set! page-title new)
        (for-each sync-head! connected))))

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

  (define page-folder (string-append (owner-folder (this-module)) "/web/page"))

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

  (define (device-id? s)
    (and (fx= (string-length s) 32)
         (for-all (lambda (c) (or (char<=? #\0 c #\9) (char<=? #\a c #\f))) (string->list s))))

  ;; Browsers keep a cookie at most 400 days.
  (define device-cookie-seconds (* 400 24 60 60))

  (define first-screen-wait 10)

  ;; The page waits for the batch that adds its client, whose end draws
  ;; it: what batch-ended posts runs in the next batch, so its release
  ;; runs once every client is drawn.
  (define (page request)
    (if (string=? (request-path request) "/")
        (let* ([given (let ([e (assoc "tuna-device" (request-cookies request))])
                        (and e (device-id? (cdr e)) (cdr e)))]
               [device (or given (random-id))]
               [id (random-id)]
               [c (with-lock
                    (set! added (fx+ added 1))
                    (let ([c (make-client id added device links scripts-version page-title)])
                      (hashtable-set! clients-by-id id c)
                      (set! opening (cons c opening))
                      c))])
          (post-as-web (lambda () (schedule-removal! c) (set! added-now (cons c added-now)) (client-added c)))
          (let-values ([(first modules early)
                        (with-mutex lock
                          (let ([deadline (add-duration (current-time 'time-utc) (make-time 'time-duration 0 first-screen-wait))])
                            (let wait ()
                              (when (and (memq c opening) (time<? (current-time 'time-utc) deadline))
                                (condition-wait first-screens lock deadline)
                                (wait))))
                          (set! opening (remq c opening))
                          (values (let ([first (client-first c)]) (and (bytevector? first) first)) script-hrefs early-hrefs))])
            (response 200
              (if given
                  page-headers
                  (cons (set-cookie-header "tuna-device" device (cookie-path "/") (cookie-http-only)
                          (cookie-same-site (same-site strict)) (cookie-max-age device-cookie-seconds))
                        page-headers))
              (html->bytevector (shell id (client-title c) (client-links c) modules early first)))))
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

  (define (allow-hosts!)
    (let ([names (cons* (format "127.0.0.1:~a" (port)) (format "localhost:~a" (port))
                        (map string-downcase (hosts)))])
      (with-lock (set! allowed names))))

  (define (report-later e)
    (post-as-web (lambda () (report e))))

  (define heartbeat (string->utf8 ":\n\n"))

  (define (heartbeat-after t)
    (add-duration t (make-time 'time-duration 0 heartbeat-seconds)))

  ;; Once a stream's response has begun, only this thread writes to it, in
  ;; the order queued: a quit can split the stream library's own lock when
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

  (define (listen p addresses)
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
                    (route "/goodbye" (checked goodbye))
                    (route "/web/" (checked page-file))
                    (route "/files/" (checked served-file))
                    (route "/" (checked page)))))
      (server-options [on-error report-later]
                      [http1-request-io-timeout (* 4 heartbeat-seconds 1000)])))

  (define (current-settings) (list (port) (listen-also) (proxy-secret-file)))

  ;; An address that cannot be listened on, such as a proxy network not up
  ;; yet, leaves Tuna on 127.0.0.1 rather than nowhere.
  (define (start-server!)
    (set! started? #t)
    (let ([p (port)] [also (proxy-address)] [me (list 'sender)])
      (allow-hosts!)
      (retitle!)
      (set! server
        (if also
            (guard (e [(not (quit-condition? e)) (report e) (listen p '("127.0.0.1"))])
              (listen p (list "127.0.0.1" also)))
            (listen p '("127.0.0.1"))))
      (set! server-settings (current-settings))
      (with-lock (set! sender me))
      (fork-thread (lambda () (send-loop me)))
      (printf "Tuna is at http://127.0.0.1:~a/\n" p)
      (flush-output-port (current-output-port))))

  (define (stop-server!)
    (with-lock
      (set! sender #f)
      (condition-broadcast wake))
    (let ([s server])
      (set! server #f)
      (when s (server-stop! s))))

  ;; Taking back a setting, as at exit or when the configuration is
  ;; evaluated again, changes the port too, so the server moves only once
  ;; the code running now has finished, and only if a setting is new.
  (define (restart-server!)
    (when started?
      (as-module (this-module)
        (post! (lambda ()
                 (unless (and server (equal? server-settings (current-settings)))
                   (stop-server!)
                   (start-server!)))))))

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

  (record-writer (record-type-descriptor client)
    (lambda (c p wr) (fprintf p "#<client ~a>" (client-number c)))))

(import %internals)

(define-option port 7337 (lambda (v) (and (fixnum? v) (fx<= 1 v 65535)))
  "The port Tuna listens on, on 127.0.0.1 and on web:listen-also."
  (lambda (v) (restart-server!)))

(define-option hosts '() (lambda (v) (and (list? v) (for-all string? v)))
  "Host names, as a Host header gives them, that reach the port besides 127.0.0.1 and localhost."
  (lambda (v) (allow-hosts!)))

(define-option listen-also #f (lambda (v) (or (not v) (string? v)))
  "A second numeric address the port is listened on, for a reverse proxy; needs web:proxy-secret-file."
  (lambda (v) (restart-server!)))

(define-option proxy-secret-file #f
  ;; Chez counts ~user/ as absolute too, but only ~/ is expanded here.
  (lambda (v)
    (or (not v)
        (and (string? v) (path-absolute? v)
             (or (home-path? v) (not (char=? (string-ref v 0) #\~))))))
  "The file, of mode 600, whose text a request from a peer other than 127.0.0.1 or ::1 must give as Tuna-Proxy-Secret."
  (lambda (v) (restart-server!)))

(define-option title "Tuna" string?
  "The title of every client's page, which its browser tab shows."
  (lambda (v) (retitle!)))

(define-hook client-added "Called with a client when its page is served.")

(define-hook client-removed "Called with a client that has been removed.")

(define-table input-handlers "Maps an item's type to a procedure of the client and the item.")

(define-table stylesheets "Maps a name to a CSS file that every page links.")

(define-table scripts "Maps a name to a JavaScript module that every page loads.")

(define-table early-scripts
  "Maps a name to a classic script that every page runs in its head, before the first screen is painted.")

(define current-client
  (make-thread-parameter #f
    (lambda (v)
      (unless (or (not v) (client-record? v))
        (assertion-violation 'web:current-client "not a client or #f" v))
      v)))

(define (clients) (connected-clients))

(define (client? v) (client-record? v))

(define (client-device client)
  (unless (client-record? client)
    (assertion-violation 'web:client-device "not a client" client))
  (client-record-device client))

(define (send-screen! client screen)
  (unless (client-record? client)
    (assertion-violation 'web:send-screen! "not a client" client))
  (unless (or (html? screen) (bytevector? screen))
    (assertion-violation 'web:send-screen! "not html or a bytevector" screen))
  (give-screen! client screen))

(define (call-page! client name value)
  (unless (client-record? client)
    (assertion-violation 'web:call-page! "not a client" client))
  (unless (and (string? name)
               (fx<= 1 (string-length name) 64)
               (for-all (lambda (c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\-)))
                        (string->list name)))
    (assertion-violation 'web:call-page! "not 1 to 64 letters, digits and hyphens" name))
  (guard (e [(json-error? e) (assertion-violation 'web:call-page! "(json) cannot write it" value)])
    (call-page client name value)))

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (post-start!)
    (release-first-screens!)
    (refresh-head-files!)))

(on-unload stop-server!)
