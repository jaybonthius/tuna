#!tuna
(import (buffers) (views) (layout) (commands) (modes))

(define-record-type (%doc %make-doc doc?)
  (sealed #t)
  (fields (immutable text doc-text) (immutable markdown? doc-markdown?) (immutable thing doc-thing)
          (immutable face doc-face) (immutable echo doc-echo) (immutable spans doc-spans)))

(define-record-type %options
  (sealed #t)
  (fields markdown? thing face echo-given? echo spans))

(define (%check-options thing face echo-given? echo spans)
  (define who 'docs-at-point:doc-options)
  (unless (or (not thing) (string? thing))
    (assertion-violation who "neither a string nor #f" thing))
  (unless (or (not face) (symbol? face))
    (assertion-violation who "neither a face nor #f" face))
  (unless (or (not echo) (string? echo))
    (assertion-violation who "neither a string nor #f" echo))
  (unless (and (list? spans)
               (for-all (lambda (s)
                          (and (list? s) (fx= (length s) 3)
                               (fixnum? (car s)) (fixnum? (cadr s)) (fx<= 0 (car s) (cadr s))
                               (symbol? (caddr s))))
                        spans))
    (assertion-violation who "not a list of a start, an end and a face" spans)))

(define-syntax doc-options
  (lambda (x)
    (define (invalid c) (syntax-violation 'docs-at-point:doc-options "invalid clause" x c))
    (syntax-case x ()
      [(_ clause ...)
       (let loop ([clauses #'(clause ...)] [given '()])
         (define (given-or name default) (let ([g (assq name given)]) (if g (cdr g) default)))
         (if (null? clauses)
             #`(%check-and-make-options #,(given-or 'markdown #'#f) #,(given-or 'thing #'#f) #,(given-or 'face #'#f)
                                        #,(if (assq 'echo given) #'#t #'#f) #,(given-or 'echo #'#f)
                                        #,(given-or 'spans #''()))
             (let* ([c (car clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (assq name given)
                 (syntax-violation 'docs-at-point:doc-options "clause given twice" x c))
               (loop (cdr clauses)
                     (cons (case name
                             [(markdown) (syntax-case c () [(_) (cons name #'#t)] [_ (invalid c)])]
                             [(thing face echo spans) (syntax-case c () [(_ e) (cons name #'e)] [_ (invalid c)])]
                             [else (invalid c)])
                           given)))))])))

(define (%check-and-make-options markdown? thing face echo-given? echo spans)
  (%check-options thing face echo-given? echo spans)
  (make-%options markdown? thing face echo-given? echo spans))

(define %no-options (make-%options #f #f #f #f #f '()))

(define make-doc
  (case-lambda
    [(text) (make-doc text %no-options)]
    [(text options)
     (unless (string? text)
       (assertion-violation 'docs-at-point:make-doc "not a string" text))
     (unless (%options? options)
       (assertion-violation 'docs-at-point:make-doc "not doc options" options))
     (%make-doc text (%options-markdown? options) (%options-thing options) (%options-face options)
                (if (%options-echo-given? options) (%options-echo options) text)
                (%options-spans options))]))

(define-hook sources
  "Called with the selected view, each entry in a task of its own, once Tuna has been idle docs-at-point:delay seconds after a command; returns a doc, a list of docs, or #f.")

(define-hook displays
  "Called with the view the docs are about, the docs to show and whether the user asked for them, each time the strategy's choice changes.")

(define (first answers)
  (let loop ([answers answers])
    (cond
      [(null? answers) '()]
      [(eq? (car answers) 'waiting) '()]
      [(pair? (car answers)) (car answers)]
      [else (loop (cdr answers))])))

(define (all answers)
  (apply append (filter pair? answers)))

(define-option strategy first procedure?
  "Chooses the docs to show from the sources' answers so far, one per entry of docs-at-point:sources, each a list of docs or the symbol waiting.")

(define-option delay 0.5 (lambda (v) (and (real? v) (finite? v) (>= v 0)))
  "Seconds of idleness after a command before the sources are asked.")

(define-option after-edits-only? #f boolean?
  "Whether the sources are asked only after a command that changed the selected view's buffer.")

(define-option mode #t boolean?
  "Whether the sources are asked after a command.")

;; An ask is about a place, as Eldoc's request state, so its answers
;; stand until the place changes and one place is not asked about twice.
(define-record-type %place
  (sealed #t)
  (fields view-id held-buffer version point))

;; The view's number and a weak pair, so the last ask keeps no dropped
;; view or killed buffer alive.
(define (%place-of view)
  (let ([b (views:buffer view)])
    (make-%place (views:id view) (weak-cons b #f) (buffers:version b) (views:point view))))

(define (%place-buffer place) (car (%place-held-buffer place)))

(define (%still? place)
  (let ([view (views:find (%place-view-id place))] [b (%place-buffer place)])
    (and view (eq? (views:buffer view) b)
         (eqv? (buffers:version b) (%place-version place))
         (eqv? (views:point view) (%place-point place)))))

(define (%same-place? a b)
  (and a b (eqv? (%place-view-id a) (%place-view-id b)) (eq? (%place-buffer a) (%place-buffer b))
       (eqv? (%place-version a) (%place-version b)) (eqv? (%place-point a) (%place-point b))))

(define %last-place #f)
(define %tasks '())

(define (%stop-asking!)
  (for-each (lambda (t) (unless (task-done? t) (signal-task t (%quit)))) %tasks)
  (set! %tasks '()))

(define %quit (record-constructor (record-constructor-descriptor &quit)))

(define (%answer-docs answer)
  (cond
    [(not answer) '()]
    [(doc? answer) (list answer)]
    [(and (list? answer) (for-all doc? answer)) answer]
    [else (assertion-violation 'docs-at-point:sources "an entry returned neither a doc, a list of docs nor #f" answer)]))

(define (%same-docs? a b)
  (and (fx= (length a) (length b)) (for-all eq? a b)))

;; An internal buffer's own text, such as a prompt's, is no place to
;; document unless a source was added for that buffer alone, as Eldoc
;; keeps to buffers that set it up.
(define (%entries view)
  (let ([entries (views:call-with-view view (lambda () (hook-entries sources)))])
    (if (buffers:internal-name? (buffers:name (views:buffer view)))
        (let ([global (parameterize ([current-scope #f]) (hook-entries sources))])
          (remp (lambda (e) (memq e global)) entries))
        entries)))

(define (%ask! view asked?)
  (%stop-asking!)
  (let* ([place (%place-of view)] [entries (%entries view)]
         [answers (make-vector (length entries) 'waiting)] [shown #f])
    (define (choose!)
      (let* ([answers (vector->list answers)]
             [docs ((views:call-with-view view strategy) answers)])
        (unless (or (and (null? docs) (memq 'waiting answers)) (and shown (%same-docs? docs shown)))
          (set! shown docs)
          (displays view docs asked?))))
    (set! %last-place place)
    (if (null? entries)
        (choose!)
        (let loop ([entries entries] [i 0])
          (unless (null? entries)
            (let ([entry (car entries)])
              (set! %tasks
                (cons (spawn-task
                        (lambda ()
                          (let ([docs (guard (c [(quit-condition? c) #f] [else (report c) '()])
                                        (%answer-docs (views:call-with-view view (lambda () (entry view)))))])
                            (when (and docs (%still? place))
                              (vector-set! answers i docs)
                              (choose!)))))
                      %tasks)))
            (loop (cdr entries) (fx+ i 1)))))))

(define ask-sources
  (case-lambda
    [() (ask-sources (layout:selected-view))]
    [(view)
     (unless (views:view? view)
       (assertion-violation 'docs-at-point:ask-sources "not a view" view))
     (%ask! view #t)]))

(define %idle-timer #f)
(define %timer-delay #f)
(define %pending? #f)
(define %before (make-weak-eq-hashtable))
(define %edited? #f)

(define (%set-timer! seconds)
  (unless (eqv? seconds %timer-delay)
    (when %idle-timer (cancel-timer! %idle-timer))
    (set! %timer-delay seconds)
    (set! %idle-timer (as-module (this-module) (run-with-idle-timer seconds %on-idle)))))

;; An edit is the ending command's own, kept by its task: a command paused
;; at a prompt ends after the prompt's own commands have run, and compared
;; with the last ask instead, a buffer never asked in would never count.
(define (%run-key) (or (current-task) 'no-task))

(define (%note-start command)
  (let ([view (layout:selected-view)])
    (eq-hashtable-set! %before (%run-key)
      (and view (views:buffer view) (cons (views:buffer view) (buffers:version (views:buffer view)))))))

(define (%note-end command)
  (let ([view (layout:selected-view)] [before (eq-hashtable-ref %before (%run-key) #f)])
    (eq-hashtable-delete! %before (%run-key))
    (set! %pending? #t)
    (set! %edited? (and before view (eq? (views:buffer view) (car before))
                        (not (eqv? (buffers:version (car before)) (cdr before)))))
    (%set-timer! (if (and view (views:buffer view)) (views:call-with-view view delay) (delay)))))

(define (%on-idle)
  (when %pending?
    (set! %pending? #f)
    (let ([view (layout:selected-view)])
      (when (and view (views:buffer view))
        (let ([place (%place-of view)])
          (when (and (not (%same-place? place %last-place))
                     (views:call-with-view view (lambda () (and (mode) (or (not (after-edits-only?)) %edited?)))))
            (cond
              [(pair? (%entries view)) (%ask! view #f)]
              [(and %last-place (eq? (%place-buffer %last-place) (views:buffer view)))
               (%stop-asking!)
               (set! %last-place place)
               (displays view '() #f)])))))))

(table-set! modes:minor-modes mode 0)
(add-hook! commands:before-command %note-start)
(add-hook! commands:after-command %note-end)
(%set-timer! (delay))
(on-unload %stop-asking!)
