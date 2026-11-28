#!tuna
(import (buffers) (document) (jobs) (modes) (hooks) (tables))

(define %self (current-owner))

(tables:define-table highlighters
  "Maps a major mode, or a language as modes:language names it, to a highlighter. A buffer's highlighter is the entry of the first mode in its mode's ancestry that has one, else the entry of its mode's language.")

(buffers:define-layer faces (priority -10) (sticky after) (evaporate))

(modes:define-minor-mode mode
  "Whether a buffer's faces are set, so a user can read a buffer in one colour. Its highlighting job runs either way."
  (default #t)
  (on-change (lambda (on?) (%note-faces-changed!))))

(module %internals
  (make-highlighter-record highlighter-record? check-main-thread note-faces-changed! note-mode-set!
   note-mode-set-delaying-hooks! note-module-loaded! stop-stale! start-pending! stop! forget-buffer! send-edit!
   update-buffer! reread-input! update-all! stop-all! buffer-data-version)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define-record-type highlighter-record
    (sealed #t)
    (fields worker layers input faces-index))

  (define-record-type state
    (sealed #t)
    (fields buffer highlighter (mutable job) (mutable input) (mutable data) (mutable data-version) (mutable faces?)
            layers))

  (define running (make-eq-hashtable))

  ;; A buffer whose job or input raised keeps the highlighter that did, so
  ;; one that always raises is not started again after every batch.
  (define failed (make-weak-eq-hashtable))

  (define restarts (make-weak-eq-hashtable))

  ;; A preview's mode is set with its hooks delayed and its job starts
  ;; then; the hooks running later complete that visit, which is no new
  ;; mode to restart for. modes:set-major-mode runs the same hook, so only
  ;; the mode the preview set counts as its visit.
  (define previewed (make-weak-eq-hashtable))

  (define check-all? #t)
  (define faces-changed? #f)

  (define (note-faces-changed!) (set! faces-changed? #t))
  (define (note-module-loaded!) (set! check-all? #t))

  (define (note-mode-set! buffer)
    (let ([preview-mode (eq-hashtable-ref previewed buffer #f)])
      (eq-hashtable-delete! previewed buffer)
      (unless (eq? preview-mode (modes:major-mode buffer))
        (eq-hashtable-set! restarts buffer #t))))

  (define (note-mode-set-delaying-hooks! buffer)
    (eq-hashtable-set! previewed buffer (modes:major-mode buffer))
    (eq-hashtable-set! restarts buffer #t))

  (define (highlighter-of buffer)
    (let ([mode (modes:major-mode buffer)])
      (or (exists (lambda (m) (tables:ref highlighters m #f)) (modes:ancestry mode))
          (let ([language (modes:language mode)])
            (and language (tables:ref highlighters language #f))))))

  (define (faces-on? buffer)
    (and (buffers:with-buffer buffer (mode)) #t))

  (define (current? s)
    (eq? (eq-hashtable-ref running (state-buffer s) #f) s))

  (define (clear! buffer layer)
    (buffers:set-spans! layer 0 (document:length (buffers:document buffer)) '()))

  (define (forget! s)
    (let ([buffer (state-buffer s)])
      (eq-hashtable-delete! running buffer)
      (when (buffers:live? buffer)
        (for-each (lambda (layer) (clear! buffer layer)) (state-layers s)))))

  (define (stop! buffer)
    (let ([s (eq-hashtable-ref running buffer #f)])
      (when s
        (forget! s)
        (jobs:stop! (state-job s)))))

  (define (fail! s)
    (let ([buffer (state-buffer s)])
      (stop! buffer)
      (eq-hashtable-set! failed buffer (state-highlighter s))))

  (define (input-of s)
    (let ([buffer (state-buffer s)])
      (buffers:with-buffer buffer
        ((highlighter-record-input (state-highlighter s)) buffer (state-data s)))))

  (define (send-input! s)
    (guard (c [(not (cancelled? c)) (report c) (fail! s)])
      (let ([input (input-of s)])
        (unless (equal? input (state-input s))
          (state-input-set! s input)
          (jobs:send! (state-job s) (cons 'input input))))))

  (define (set-updates! s version updates)
    (let ([buffer (state-buffer s)] [h (state-highlighter s)])
      (let loop ([updates updates])
        (unless (null? updates)
          (let* ([u (car updates)] [type (list-ref (highlighter-record-layers h) (car u))])
            (cond
              [(and (eq? type faces) (not (state-faces? s))) (loop (cdr updates))]
              [(buffers:set-spans! (buffers:layer buffer type) (cadr u) (caddr u) (cadddr u) version)
               (loop (cdr updates))]
              [else (jobs:send! (state-job s) '(resend))]))))))

  (define (receive! s result)
    (when (and (current? s) (buffers:live? (state-buffer s)))
      (case (car result)
        [(spans) (set-updates! s (cadr result) (caddr result))]
        [(data)
         (state-data-set! s (caddr result))
         (state-data-version-set! s (cadr result))
         (send-input! s)]
        [(data-version) (state-data-version-set! s (cdr result))])))

  (define (ended! s ended)
    (when (current? s)
      (forget! s)
      (eq-hashtable-set! failed (state-buffer s) (state-highlighter s))))

  (define (start! buffer h)
    (eq-hashtable-delete! failed buffer)
    (guard (c [(not (cancelled? c)) (report c) (eq-hashtable-set! failed buffer h)])
      (unless (highlighter-record? h)
        (assertion-violation 'syntax-highlighting:highlighters "not a highlighter" h))
      ;; The layers are taken at the start: from the first step of this
      ;; plugin's unload its layer types are out of effect, and the unload
      ;; still clears them.
      (let* ([s (make-state buffer h #f #f #f #f (faces-on? buffer)
                            (map (lambda (type) (buffers:layer buffer type)) (highlighter-record-layers h)))]
             [input (input-of s)])
        (state-input-set! s input)
        (state-job-set! s
          (jobs:start (highlighter-record-worker h)
                      (list (buffers:version buffer) (buffers:document buffer) input (state-faces? s)
                            (highlighter-record-faces-index h) (length (highlighter-record-layers h)))
                      (lambda (result) (receive! s result))
                      (lambda (ended) (ended! s ended))))
        (eq-hashtable-set! running buffer s))))

  (define (reconcile-buffer! buffer)
    (if (buffers:live? buffer)
        (let ([h (highlighter-of buffer)] [s (eq-hashtable-ref running buffer #f)])
          (cond
            [s (unless (eq? h (state-highlighter s))
                 (stop! buffer)
                 (when h (start! buffer h)))]
            [(not h) (eq-hashtable-delete! failed buffer)]
            [(eq-hashtable-contains? failed buffer)
             (unless (eq? h (eq-hashtable-ref failed buffer #f))
               (start! buffer h))]
            [else (start! buffer h)]))
        (eq-hashtable-delete! failed buffer)))

  (define (check-faces! s)
    (let ([on? (faces-on? (state-buffer s))])
      (unless (eq? on? (state-faces? s))
        (state-faces?-set! s on?)
        (when (highlighter-record-faces-index (state-highlighter s))
          (unless on? (clear! (state-buffer s) (buffers:layer (state-buffer s) faces)))
          (jobs:send! (state-job s) (cons 'faces on?))))))

  ;; Spans go before the rest of the batch's end, where screens are drawn
  ;; by advice loaded before or after this, so a buffer whose faces were
  ;; turned off, or whose job stopped, is not drawn with them.
  (define (stop-stale!)
    (vector-for-each
      (lambda (buffer)
        (when (buffers:live? buffer)
          (stop! buffer)))
      (hashtable-keys restarts))
    (vector-for-each
      (lambda (s)
        (let ([buffer (state-buffer s)])
          (unless (and (buffers:live? buffer) (eq? (highlighter-of buffer) (state-highlighter s)))
            (stop! buffer)
            (eq-hashtable-set! restarts buffer #t))))
      (hashtable-values running))
    (when faces-changed?
      (set! faces-changed? #f)
      (vector-for-each check-faces! (hashtable-values running))))

  ;; Jobs start at the end of the batch, so the views that show their
  ;; buffers by then are there for their input to read.
  (define (start-pending!)
    (let ([again (hashtable-keys restarts)])
      (hashtable-clear! restarts)
      (vector-for-each
        (lambda (buffer)
          (when (buffers:live? buffer)
            (stop! buffer)
            (eq-hashtable-delete! failed buffer)))
        again)
      (vector-for-each reconcile-buffer! again))
    (if check-all?
        (begin
          (set! check-all? #f)
          (for-each reconcile-buffer! (buffers:all)))
        (vector-for-each reconcile-buffer! (hashtable-keys failed))))

  (define (forget-buffer! buffer)
    (stop! buffer)
    (eq-hashtable-delete! failed buffer)
    (eq-hashtable-delete! restarts buffer)
    (eq-hashtable-delete! previewed buffer))

  ;; The removed text's length in characters needs the removed piece,
  ;; which only the main thread holds.
  (define (send-edit! buffer edit)
    (let ([s (eq-hashtable-ref running buffer #f)])
      (when s
        (let* ([doc (buffers:document buffer)] [unit (document:unit characters)]
               [start (buffers:edit-start edit)]
               [start-offset (document:offset doc start unit)]
               [inserted (fx- (document:offset doc (fx+ start (buffers:piece-length (buffers:edit-inserted edit))) unit)
                              start-offset)]
               [removed-doc (buffers:piece-document (buffers:edit-removed edit))]
               [removed (document:offset removed-doc (document:length removed-doc) unit)])
          (jobs:send! (state-job s)
                      (cons* 'edit (buffers:version buffer) start-offset removed inserted doc))))))

  (define (update-buffer! buffer)
    (let ([s (eq-hashtable-ref running buffer #f)])
      (cond
        [s (send-input! s)]
        [(eq-hashtable-contains? failed buffer)
         (eq-hashtable-delete! failed buffer)
         (eq-hashtable-set! restarts buffer #t)])))

  (define (reread-input! buffer)
    (let ([s (eq-hashtable-ref running buffer #f)])
      (when s (send-input! s))))

  (define (update-all!)
    (vector-for-each send-input! (hashtable-values running)))

  (define (stop-all!)
    (vector-for-each stop! (hashtable-keys running)))

  (define (buffer-data-version buffer)
    (let ([s (eq-hashtable-ref running buffer #f)])
      (and s (state-data-version s))))

  (record-writer (record-type-descriptor highlighter-record)
    (lambda (h p wr) (display "#<highlighter>" p))))

(import %internals)

(define (make-highlighter worker layers input)
  (unless (jobs:worker? worker)
    (assertion-violation 'syntax-highlighting:make-highlighter "not a worker" worker))
  (unless (and (pair? layers) (list? layers) (for-all symbol? layers))
    (assertion-violation 'syntax-highlighting:make-highlighter "not a list of layer types" layers))
  (unless (procedure? input)
    (assertion-violation 'syntax-highlighting:make-highlighter "not a procedure" input))
  (make-highlighter-record worker layers input
    (let loop ([types layers] [i 0])
      (cond
        [(null? types) #f]
        [(eq? (car types) faces) i]
        [else (loop (cdr types) (fx+ i 1))]))))

(define (highlighter? v) (highlighter-record? v))

(define update!
  (case-lambda
    [()
     (check-main-thread 'syntax-highlighting:update!)
     (update-all!)]
    [(buffer)
     (check-main-thread 'syntax-highlighting:update!)
     (unless (buffers:buffer? buffer)
       (assertion-violation 'syntax-highlighting:update! "not a buffer" buffer))
     (update-buffer! buffer)]))

(define (input-changed! buffer)
  (check-main-thread 'syntax-highlighting:input-changed!)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'syntax-highlighting:input-changed! "not a buffer" buffer))
  (reread-input! buffer))

(define (data-version buffer)
  (check-main-thread 'syntax-highlighting:data-version)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'syntax-highlighting:data-version "not a buffer" buffer))
  (buffer-data-version buffer))

(define (%note-faces-changed!) (note-faces-changed!))

(define (%mode-set buffer) (note-mode-set! buffer))

(define (%mode-set-delaying-hooks buffer) (note-mode-set-delaying-hooks! buffer))

(define (%send-edit buffer edit) (send-edit! buffer edit))

(define (%note-module-loaded loaded name)
  (loaded name)
  (note-module-loaded!))

(define (%reconcile ended)
  (call-as-owner %self (lambda () (stop-stale!)))
  (ended)
  (call-as-owner %self (lambda () (start-pending!))))

(hooks:add! modes:major-mode-changed %mode-set)
(hooks:add! modes:delayed-mode-changed %mode-set-delaying-hooks)
(hooks:add! buffers:killed forget-buffer!)
(hooks:add! buffers:after-edit %send-edit)
(advice-add! module-loaded %note-module-loaded)
(advice-add! batch-ended %reconcile)
(on-unload stop-all!)
