#!tuna
(import (processes) (jobs) (buffers) (document) (modes) (json-rpc framing) (json-rpc) (jsonrpc log-lines))

(define-option request-timeout 10 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds jsonrpc:request waits by default.")

(define-option events-log-size 2000000 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How many characters each connection's events log keeps; the oldest lines go first, and with 0 nothing is logged."
  (lambda (size) (%events-log-size-changed size)))

(define-condition-type &ended &error %make-ended ended?
  (status ended-status))

(define-condition-type &timeout &error %make-timeout timeout?
  (method timeout-method))

(define-table events-keymap "Keys in events logs.")

(define-hook events-mode-hook "Called in each buffer that turns on jsonrpc:events-mode.")

(modes:define-major-mode events-mode
  (parent modes:special)
  (lighter "Events")
  (keymap events-keymap)
  (hook events-mode-hook))

(define (%no-revert)
  (set-option-local! buffers:revert-function #f))

(define (%refuse-edits node edit) #f)

(buffers:define-kind %events (consent %refuse-edits))

;; Frames are read and parsed off the main thread, and the events log's
;; lines made there too, since one answer can hold a project's diagnostics
;; or a long completion list. The job is told whether the log is on, so it
;; makes no line the log would drop. A piece's stray bytes are emitted
;; after its bodies, so the events log keeps their order within the piece
;; as well as it can.
(jobs:define-worker (%reader log? emit receive)
  (import (json-rpc framing) (json) (jsonrpc log-lines))
  (define (message-of c)
    (cond
      [(not (message-condition? c)) "not JSON"]
      [(and (format-condition? c) (irritants-condition? c))
       (apply format (condition-message c) (condition-irritants c))]
      [else (condition-message c)]))
  (let* ([stray '()]
         [reader (make-frame-reader (lambda (bytes) (when log? (set! stray (cons bytes stray)))))])
    (let loop ()
      (let ([piece (receive)])
        (case piece
          [(end) (void)]
          [(log-on log-off) (set! log? (eq? piece 'log-on)) (loop)]
          [else
           (for-each
             (lambda (x)
               (emit
                 (cond
                   [(frame-error? x) (vector 'frame-error (condition-message x))]
                   [else
                    (let ([line (and log? (log-line "<-- " (utf8->string x)))])
                      (guard (c [(json-error? c) (vector 'not-json line (message-of c))])
                        (vector 'body line (bytevector->json x))))])))
             (frame-reader-read! reader piece))
           (unless (null? stray)
             (emit (vector 'stray (log-lines "stray: " (apply string-append (map utf8->string (reverse stray))))))
             (set! stray '()))
           (loop)])))))

(module %internals
  (make-handlers handlers? handlers-request handlers-notification handlers-cancel handlers-exit
   make-connection is-connection? %connection-name %connection-process %connection-process-set!
   %connection-job %connection-job-set! %connection-handlers %connection-owner
   %connection-running? %connection-running?-set! %connection-status %connection-status-set!
   %connection-pending next-id! %connection-end-sent? %connection-end-sent?-set!
   %connection-job-ended? %connection-job-ended?-set! %connection-finished? %connection-finished?-set!
   %connection-events %connection-events-set!
   %connection-frame-error-reported? %connection-frame-error-reported?-set!
   make-pending is-pending? %pending-connection %pending-id %pending-method %pending-waiting?
   pending-done! %pending-resume %pending-resume-set! %pending-timer-set!
   %pending-on-result %pending-on-error %pending-owner
   make-events-log %events-log-buffer
   connections remember-connection! forget-connection! append-to-log!)

  (define-record-type (%handlers make-handlers handlers?)
    (sealed #t)
    (fields (immutable request handlers-request) (immutable notification handlers-notification)
            (immutable cancel handlers-cancel) (immutable exit handlers-exit)))

  (define-record-type (%connection make-connection is-connection?)
    (sealed #t)
    (fields name handlers owner pending
            (mutable process) (mutable job) (mutable running?) (mutable status)
            (mutable next-id) (mutable end-sent?) (mutable job-ended?) (mutable finished?)
            (mutable events) (mutable frame-error-reported?))
    (protocol
      (lambda (new)
        (lambda (name handlers owner)
          (new name handlers owner (make-eqv-hashtable) #f #f #t #f 0 #f #f #f #f #f)))))

  (define (next-id! c)
    (let ([id (fx+ (%connection-next-id c) 1)])
      (%connection-next-id-set! c id)
      id))

  (define-record-type (%pending make-pending is-pending?)
    (sealed #t)
    (fields connection id method owner on-result on-error
            (mutable waiting?) (mutable resume) (mutable timer))
    (protocol
      (lambda (new)
        (lambda (connection id method owner on-result on-error)
          (new connection id method owner on-result on-error #t #f #f)))))

  (define (pending-done! p)
    (%pending-waiting?-set! p #f)
    (hashtable-delete! (%connection-pending (%pending-connection p)) (%pending-id p))
    (when (%pending-timer p)
      (cancel-timer! (%pending-timer p))
      (%pending-timer-set! p #f)))

  (define connections '())

  (define (remember-connection! c) (set! connections (cons c connections)))

  (define (forget-connection! c) (set! connections (remq c connections)))

  ;; The log's lines are counted in a queue of their lengths, so trimming
  ;; never reads the buffer's text.
  (define-record-type (%events-log make-events-log events-log?)
    (sealed #t)
    (fields buffer (mutable total) (mutable head) (mutable tail))
    (protocol (lambda (new) (lambda (buffer) (new buffer 0 '() '())))))

  (define (append-to-log! c line)
    (let* ([buffer (events-buffer c)] [log (%connection-events c)]
           [doc (buffers:document buffer)] [end (fx- (document:length doc) 1)]
           [n (fx+ (string-length line) 1)] [cell (list n)])
      (buffers:splice! buffer end end (document:from-datum (string-append line "\n")))
      (if (null? (%events-log-head log))
          (%events-log-head-set! log cell)
          (set-cdr! (%events-log-tail log) cell))
      (%events-log-tail-set! log cell)
      (%events-log-total-set! log (+ (%events-log-total log) n))
      (trim-log! log)))

  (define (trim-log! log)
    (let ([size (events-log-size)])
      (let loop ([drop 0])
        (if (and (> (%events-log-total log) size) (pair? (%events-log-head log)))
            (let ([n (car (%events-log-head log))])
              (%events-log-head-set! log (cdr (%events-log-head log)))
              (%events-log-total-set! log (- (%events-log-total log) n))
              (loop (+ drop n)))
            (when (> drop 0)
              (buffers:splice! (%events-log-buffer log) 1 (+ 1 drop) (document:from-datum "")))))))

  (record-writer (record-type-descriptor %connection)
    (lambda (c port write) (fprintf port "#<jsonrpc-connection ~a>" (%connection-name c))))

  (record-writer (record-type-descriptor %pending)
    (lambda (p port write)
      (fprintf port "#<jsonrpc-pending ~a ~a>" (%connection-name (%pending-connection p)) (%pending-method p)))))

(import %internals)

;; The line is an expression so that, with the log off, a message is not
;; decoded only to be dropped. A line the job did not make is #f.
(define-syntax %log!
  (syntax-rules ()
    [(_ c line) (when (> (events-log-size) 0) (let ([l line]) (when l (append-to-log! c l))))]))

(define-syntax handlers
  (lambda (x)
    (define names '(request notification cancel exit))
    (define (check-names given)
      (let loop ([given given] [seen '()])
        (unless (null? given)
          (let ([name (syntax->datum (car given))])
            (unless (memq name names)
              (syntax-violation 'jsonrpc:handlers "unknown clause" x (car given)))
            (when (memq name seen)
              (syntax-violation 'jsonrpc:handlers "clause given twice" x (car given)))
            (loop (cdr given) (cons name seen))))))
    (syntax-case x ()
      [(_ [name value] ...)
       (for-all identifier? #'(name ...))
       (begin
         (check-names #'(name ...))
         (with-syntax ([(temporary ...) (generate-temporaries #'(name ...))])
           (with-syntax ([(argument ...)
                          (let ([given (map cons (syntax->datum #'(name ...)) #'(temporary ...))])
                            (map (lambda (name) (cond [(assq name given) => cdr] [else #'#f])) names))])
             #'(let* ([temporary value] ...) (%make-checked-handlers argument ...)))))]
      [_ (syntax-violation 'jsonrpc:handlers "expected (jsonrpc:handlers [name procedure] ...)" x)])))

(define (%make-checked-handlers on-request on-notification on-cancel on-exit)
  (for-each
    (lambda (p)
      (unless (or (not p) (procedure? p))
        (assertion-violation 'jsonrpc:handlers "not a procedure" p)))
    (list on-request on-notification on-cancel on-exit))
  (make-handlers on-request on-notification on-cancel on-exit))

(define (%check-connection who c)
  (unless (is-connection? c)
    (assertion-violation who "not a jsonrpc connection" c)))

(define (%check-method who method)
  (unless (string? method)
    (assertion-violation who "not a string" method)))

(define (%params? v)
  (or (eq? v 'null) (vector? v) (and (list? v) (for-all pair? v))))

(define (%check-params who params)
  (unless (%params? params)
    (assertion-violation who "not a JSON object, array or null" params)))

(define (%ended c)
  (condition (%make-ended (%connection-status c)) (make-who-condition 'jsonrpc)
    (make-message-condition (format "~a ended" (%connection-name c)))))

(define (%reporting thunk)
  (guard (e [(not (quit-condition? e)) (report e)])
    (thunk)))

(define (%send! c message)
  (let ([bytes (json-rpc-message->bytevector message)])
    (%log! c (log-line "--> " (utf8->string bytes)))
    (processes:send! (%connection-process c) (body->frame bytes))))

(define (%call-cancel! c id)
  (let ([cancel (handlers-cancel (%connection-handlers c))])
    (when cancel
      (%reporting (lambda () (as-module (%connection-owner c) (cancel c id)))))))

(define start
  (case-lambda
    [(name command handlers) (start name command handlers #f)]
    [(name command handlers options)
     (unless (string? name)
       (assertion-violation 'jsonrpc:start "not a string" name))
     (unless (and (list? command) (pair? command) (for-all string? command))
       (assertion-violation 'jsonrpc:start "not a list of a program and its arguments" command))
     (unless (handlers? handlers)
       (assertion-violation 'jsonrpc:start "not jsonrpc:handlers" handlers))
     (when options
       (unless (processes:options? options)
         (assertion-violation 'jsonrpc:start "not processes:options" options))
       (when (processes:options-terminal options)
         (assertion-violation 'jsonrpc:start "a connection has no terminal" options))
       (when (processes:options-separate-stderr options)
         (assertion-violation 'jsonrpc:start "a connection keeps standard error apart itself" options)))
     (let* ([c (make-connection name handlers (current-owner))]
            [stderr (processes:line-receiver 0
                      (lambda (line end)
                        (unless (or (eof-object? line) (%connection-finished? c)) (%log! c (log-line "stderr: " line)))))])
       (%connection-job-set! c
         (jobs:start %reader (> (events-log-size) 0)
           (lambda (value) (unless (%connection-finished? c) (%parsed! c value)))
           (lambda (ended) (unless (%connection-finished? c) (%job-ended! c)))))
       (remember-connection! c)
       (%connection-process-set! c
         (guard (e [#t (jobs:stop! (%connection-job c)) (forget-connection! c) (raise e)])
           (processes:start (car command) (cdr command)
             (lambda (bytes end)
               (unless (%connection-finished? c)
                 (if (eof-object? bytes)
                     (%end-reading! c)
                     (jobs:send! (%connection-job c) bytes))))
             (lambda (status) (unless (%connection-finished? c) (%exited! c status)))
             (processes:options
               [directory (and options (processes:options-directory options))]
               [environment (and options (processes:options-environment options))])
             stderr)))
       c)]))

(define (%events-log-size-changed size)
  (for-each
    (lambda (c)
      (unless (or (%connection-end-sent? c) (%connection-job-ended? c) (%connection-finished? c))
        (jobs:send! (%connection-job c) (if (> size 0) 'log-on 'log-off))))
    connections))

(define (%end-reading! c)
  (unless (%connection-end-sent? c)
    (%connection-end-sent?-set! c #t)
    (jobs:send! (%connection-job c) 'end)))

(define (%exited! c status)
  (%connection-running?-set! c #f)
  (%connection-status-set! c status)
  (%end-reading! c)
  (%finish-if-done! c))

(define (%job-ended! c)
  (%connection-job-ended?-set! c #t)
  (%finish-if-done! c))

;; Answers still in the job when the program exits are delivered before
;; the waiting requests fail, so an exit after its last answer loses none.
(define (%finish-if-done! c)
  (when (and (not (%connection-running? c)) (%connection-job-ended? c) (not (%connection-finished? c)))
    (%connection-finished?-set! c #t)
    (forget-connection! c)
    (let-values ([(ids waiting) (hashtable-entries (%connection-pending c))])
      (vector-for-each (lambda (p) (%fail! p (%ended c))) waiting))
    (let ([on-exit (handlers-exit (%connection-handlers c))])
      (when on-exit
        (%reporting (lambda () (as-module (%connection-owner c) (on-exit c (%connection-status c)))))))))

(define (%answer! p value)
  (pending-done! p)
  (if (%pending-resume p)
      ((%pending-resume p) (lambda () value))
      (%run-for p (%pending-on-result p) value)))

(define (%fail! p condition)
  (pending-done! p)
  (if (%pending-resume p)
      ((%pending-resume p) (lambda () (raise condition)))
      (%run-for p (%pending-on-error p) condition)))

;; The procedures of an async request run for the module that sent it; one
;; that has been unloaded since gets nothing. The configuration and the
;; REPL are never unloaded, and loaded-modules does not list them.
(define (%run-for p procedure value)
  (let ([owner (%pending-owner p)])
    (when (or (member owner '((init) (repl))) (member owner (loaded-modules)))
      (as-module owner (spawn-task (lambda () (procedure value)))))))

(define (%parsed! c value)
  (case (vector-ref value 0)
    [(body)
     (%log! c (vector-ref value 1))
     (let ([message (guard (e [(json-rpc-error? e)
                               (%log! c (log-line "not a JSON-RPC message: " (condition-message e)))
                               #f])
                      (json->json-rpc-message (vector-ref value 2)))])
       (when message (%received! c message)))]
    [(not-json)
     (%log! c (vector-ref value 1))
     (%log! c (log-line "not JSON: " (vector-ref value 2)))]
    [(stray) (for-each (lambda (line) (%log! c line)) (vector-ref value 1))]
    [(frame-error) (%frame-error! c (vector-ref value 1))]))

;; Only the first is reported, so a program that keeps writing stray
;; headers does not fill the echo area.
(define (%frame-error! c message)
  (%log! c (log-line "frame error: " message))
  (unless (%connection-frame-error-reported? c)
    (%connection-frame-error-reported?-set! c #t)
    (report (condition (make-warning) (make-who-condition 'jsonrpc)
              (make-message-condition (format "~a broke the framing: ~a; its events log has the rest"
                                        (%connection-name c) message))))))

(define (%received! c message)
  (cond
    [(json-rpc-response? message)
     (let ([p (hashtable-ref (%connection-pending c) (json-rpc-response-id message) #f)])
       (cond
         [(not p) (%log! c (format "no request waits for: ~s" (json-rpc-response-id message)))]
         [(json-rpc-response-error message) => (lambda (e) (%fail! p e))]
         [else (%answer! p (json-rpc-response-result message))]))]
    [(json-rpc-notification? message)
     (let ([notification (handlers-notification (%connection-handlers c))])
       (when notification
         (%reporting
           (lambda ()
             (as-module (%connection-owner c)
               (notification c (json-rpc-notification-method message) (json-rpc-notification-params message)))))))]
    [(json-rpc-request? message)
     (as-module (%connection-owner c) (spawn-task (lambda () (%answer-request! c message))))]))

(define (%answer-request! c message)
  (let ([id (json-rpc-request-id message)] [method (json-rpc-request-method message)]
        [answer (handlers-request (%connection-handlers c))])
    (define (send-error! e) (when (%connection-running? c) (%send! c (make-json-rpc-error-response id e))))
    (cond
      [(not answer)
       (send-error! (make-json-rpc-error json-rpc-method-not-found-code (string-append "method not found: " method)))]
      [else
       (let ([result (guard (e [(json-rpc-error? e) (send-error! e) #f]
                               [(quit-condition? e) (raise e)]
                               [else
                                (report e)
                                (send-error! (make-json-rpc-error json-rpc-internal-error-code (%message-of e)))
                                #f])
                       (list (answer c method (json-rpc-request-params message))))])
         (when (and result (%connection-running? c))
           (%send! c (make-json-rpc-response id (car result)))))])))

(define (%message-of e)
  (cond
    [(not (message-condition? e)) "internal error"]
    [(and (format-condition? e) (irritants-condition? e))
     (apply format (condition-message e) (condition-irritants e))]
    [else (condition-message e)]))

(define (%new-pending! who c method params owner on-result on-error)
  (%check-connection who c)
  (%check-method who method)
  (%check-params who params)
  (let* ([id (next-id! c)] [p (make-pending c id method owner on-result on-error)])
    (hashtable-set! (%connection-pending c) id p)
    (values p (make-json-rpc-request id method params))))

(define request
  (case-lambda
    [(c method params) (request c method params (request-timeout))]
    [(c method params timeout)
     (unless (or (not timeout) (and (real? timeout) (>= timeout 0)))
       (assertion-violation 'jsonrpc:request "not a number of seconds or #f" timeout))
     (let-values ([(p message) (%new-pending! 'jsonrpc:request c method params #f #f #f)])
       (unless (%connection-running? c)
         (pending-done! p)
         (raise (%ended c)))
       (with-exception-handler
         (lambda (e)
           (when (%pending-waiting? p)
             (pending-done! p)
             (%call-cancel! c (%pending-id p)))
           (raise-continuable e))
         (lambda ()
           (suspend
             (lambda (resume)
               (%pending-resume-set! p resume)
               (%send! c message)
               (when timeout
                 (%pending-timer-set! p
                   (run-with-timer timeout
                     (lambda ()
                       (when (%pending-waiting? p)
                         (%fail! p (condition (%make-timeout method) (make-who-condition 'jsonrpc:request)
                                     (make-message-condition
                                       (format "~a gave no answer to ~a in ~a s" (%connection-name c) method timeout))))))))))))))]))

(define (request-async c method params on-result on-error)
  (unless (procedure? on-result)
    (assertion-violation 'jsonrpc:request-async "not a procedure" on-result))
  (unless (procedure? on-error)
    (assertion-violation 'jsonrpc:request-async "not a procedure" on-error))
  (let-values ([(p message) (%new-pending! 'jsonrpc:request-async c method params (current-owner) on-result on-error)])
    (if (%connection-running? c)
        (%send! c message)
        (%fail! p (%ended c)))
    p))

(define (cancel! p)
  (unless (is-pending? p)
    (assertion-violation 'jsonrpc:cancel! "not a pending request" p))
  (when (%pending-waiting? p)
    (pending-done! p)
    (%call-cancel! (%pending-connection p) (%pending-id p))))

(define (notify c method params)
  (%check-connection 'jsonrpc:notify c)
  (%check-method 'jsonrpc:notify method)
  (%check-params 'jsonrpc:notify params)
  (when (%connection-running? c)
    (%send! c (make-json-rpc-notification method params))))

(define (stop! c)
  (%check-connection 'jsonrpc:stop! c)
  (processes:stop! (%connection-process c)))

(define (running? c)
  (%check-connection 'jsonrpc:running? c)
  (%connection-running? c))

(define (connection-name c)
  (%check-connection 'jsonrpc:connection-name c)
  (%connection-name c))

(define (connection-process c)
  (%check-connection 'jsonrpc:connection-process c)
  (%connection-process c))

(define (connection? v) (is-connection? v))

(define (pending? v) (is-pending? v))

(define (events-buffer c)
  (%check-connection 'jsonrpc:events-buffer c)
  (let ([log (%connection-events c)])
    (if (and log (buffers:live? (%events-log-buffer log)))
        (%events-log-buffer log)
        (let ([b (buffers:make (buffers:free-name (string-append "*" (%connection-name c) " events*")) (%events '()))])
          (buffers:set-silent! b #t)
          (modes:set-major-mode events-mode b)
          (%connection-events-set! c (make-events-log b))
          b))))

;; A connection's process, job and waiting tasks may belong to a module
;; that stays loaded, so the requests fail now and the process's and job's
;; procedures, which call this plugin's, are told it is gone before they
;; are stopped.
(on-unload
  (lambda ()
    (for-each
      (lambda (c)
        (%connection-finished?-set! c #t)
        (let-values ([(ids waiting) (hashtable-entries (%connection-pending c))])
          (vector-for-each (lambda (p) (%fail! p (%ended c))) waiting))
        (processes:stop! (%connection-process c))
        (jobs:stop! (%connection-job c)))
      connections)))

(add-hook! events-mode-hook %no-revert)
