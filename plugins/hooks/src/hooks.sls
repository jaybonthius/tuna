#!tuna
(import (scopes) (owned))

;; A hook's global entries live in owned's set of its full name, so they
;; outlive a reload of the defining module or of hooks. Entries run in order
;; of depth, then owner rank, then the order each owner added them; the
;; order in effect is worked out at each change, so a call reads one field.
(define-record-type (%hook %make-hook %hook?)
  (nongenerative)
  (sealed #t)
  (fields symbol (mutable doc) set key (mutable entries) (mutable localized?))
  (protocol
    (lambda (new)
      (lambda (symbol doc set)
        (let ([key (scopes:make-key symbol)])
          (new symbol doc set key '() (pair? (scopes:holding key))))))))

;; An entry in effect: its owner, procedure and depth, and the procedure
;; hooks:entries gives for it, one per owner and procedure, so it stays the
;; same while the entry does, across the refreshes other changes make. The
;; runner is found when hooks:entries first asks for it, since finding it
;; takes a mutex and a call of the hook needs none.
(define-record-type (%entry %make-entry %entry?)
  (nongenerative)
  (sealed #t)
  (fields owner procedure depth (mutable runner))
  (protocol
    (lambda (new)
      (lambda (owner procedure depth)
        (new owner procedure depth #f)))))

;; Local entries are kept in the scopes, which outlive a reload of this
;; module, so the record type stays the same while its shape does.
(define-record-type (%local %make-local %local?)
  (nongenerative hooks:local/owner/procedure/depth/removal?/sequence)
  (sealed #t)
  (fields owner procedure depth removal? sequence))

(define %hooks (make-eq-hashtable))
(define %by-procedure (make-weak-eq-hashtable))

(define (%full-symbol module name)
  (if (member module '((init) (repl)))
      name
      (string->symbol (format "~{~a~^/~}:~a" module name))))

;; In a module, so Chez may inline these calls, as it never does a call of
;; a changeable procedure: a call of a hook makes several.
(module %internals (%runner-of %refresh! %changed! %hook-of %entries-now %run %note-definer! %unloaded-definition?)
  (define (%runner-of e)
    (or (%entry-runner e)
        (let ([runner (%runner (%entry-owner e) (%entry-procedure e))])
          (%entry-runner-set! e runner)
          runner)))

  (define %runners (make-ephemeron-eq-hashtable))
  (define %runners-mutex (make-mutex))

  ;; hooks:entries may be called on any thread.
  (define (%runner owner procedure)
    (with-mutex %runners-mutex
      (let ([known (hashtable-ref %runners procedure '())])
        (cond
          [(assq owner known) => cdr]
          [else
           (let ([runner (lambda arguments (call-as-owner owner (lambda () (apply procedure arguments))))])
             (hashtable-set! %runners procedure (cons (cons owner runner) known))
             runner)]))))

  (define (%depth<? a b) (< (%entry-depth a) (%entry-depth b)))

  (define (%refresh! h)
    (%hook-entries-set! h
      (list-sort %depth<?
        (map (lambda (e) (%make-entry (owned:entry-owner e) (owned:entry-key e) (owned:entry-value e)))
             (owned:entries (%hook-set h))))))

  ;; After the current owner changed its entry for proc, only proc's entries
  ;; move, and the owner's new entry, its latest, goes after every entry
  ;; that precedes it in depth and rank. An entry the change brings back into
  ;; effect, as when an add takes the place of the owner's removal, has a
  ;; place that only the order the owners added theirs gives, so the whole
  ;; list is worked out again then.
  (define (%changed! h proc)
    (let ([o (current-owner)] [now (owned:key-entries (%hook-set h) proc)] [old (%hook-entries h)])
      (define (of-proc? e) (eq? (%entry-procedure e) proc))
      (define (held-before? e)
        (exists (lambda (x) (and (of-proc? x) (eq? (%entry-owner x) (owned:entry-owner e)))) old))
      (if (for-all (lambda (e) (or (eq? (owned:entry-owner e) o) (held-before? e))) now)
          (let ([kept (remp (lambda (x)
                              (and (of-proc? x)
                                   (or (eq? (%entry-owner x) o)
                                       (not (exists (lambda (e) (eq? (owned:entry-owner e) (%entry-owner x))) now)))))
                            old)]
                [mine (find (lambda (e) (eq? (owned:entry-owner e) o)) now)])
            (%hook-entries-set! h
              (if mine
                  (let ([depth (owned:entry-value mine)])
                    (let insert ([es kept])
                      (if (or (null? es)
                              (let ([d (%entry-depth (car es))])
                                (or (< depth d) (and (= depth d) (owner<? o (%entry-owner (car es)))))))
                          (cons (%make-entry o proc depth) es)
                          (cons (car es) (insert (cdr es))))))
                  kept)))
          (%refresh! h))))

  (define (%hook-of who h)
    (or (and (procedure? h) (hashtable-ref %by-procedure h #f))
        (assertion-violation who "not a hook" h)))

  (define (%local-entries h)
    (let ([s (scopes:current)])
      (if s
          (let ([items (scopes:ref s (%hook-key h))])
            (if items (%local-in-effect items) '()))
          '())))

  (define (%local-in-effect items)
    (let loop ([items (reverse (list-sort %local<? items))] [kept '()])
      (cond
        [(null? items) (list-sort %depth<? kept)]
        [(not (owner-live? (%local-owner (car items)))) (loop (cdr items) kept)]
        [(%local-removal? (car items))
         (let ([p (%local-procedure (car items))])
           (loop (remp (lambda (i) (eq? (%local-procedure i) p)) (cdr items)) kept))]
        [else (loop (cdr items)
                    (cons (%make-entry (%local-owner (car items)) (%local-procedure (car items)) (%local-depth (car items)))
                          kept))])))

  (define (%local<? a b)
    (or (owner<? (%local-owner a) (%local-owner b))
        (and (eq? (%local-owner a) (%local-owner b)) (fx< (%local-sequence a) (%local-sequence b)))))

  (define (%entries-now h)
    (let ([global (%hook-entries h)])
      (if (%hook-localized? h)
          (let ([local (%local-entries h)])
            (if (null? local) global (merge %depth<? global local)))
          global)))

  ;; The kernel offers no test of a changeable procedure, its readers
  ;; refusing any other value, and names no definer once that instance has
  ;; unloaded. So each entry procedure's definer is kept from when it was
  ;; loaded, and #f for a procedure that is not changeable; one first seen
  ;; with no loaded definer is taken for a definition whose module is gone.
  ;; hooks:entries may be called on any thread.
  (define %definers (make-weak-eq-hashtable))
  (define %definers-mutex (make-mutex))

  (define (%note-definer! p)
    (with-mutex %definers-mutex
      (let ([known (hashtable-ref %definers p 'unknown)])
        (if (eq? known 'unknown)
            (let ([changes (guard (c [(assertion-violation? c) 'none]) (definition-changes p))])
              (cond
                [(eq? changes 'none) (hashtable-set! %definers p #f) #f]
                [(find (lambda (change) (eq? (cadr change) 'define)) changes)
                 => (lambda (change) (hashtable-set! %definers p (car change)) (car change))]
                [else 'unknown]))
            known))))

  ;; A definition its loaded module no longer defines does not count: a
  ;; call of it is a mistake to report.
  (define (%unloaded-definition? p)
    (let ([o (%note-definer! p)])
      (or (eq? o 'unknown)
          (and o (not (owner-live? o)) (not (module-owner (owner-name o)))))))

  ;; One escape and one handler per call, not per entry. A raise is reported
  ;; where it happens and the next entry runs; a cancel meant for the task
  ;; goes on to end it; an entry whose owner's unload began, before or while
  ;; it runs, is skipped. Entries run in the caller's mask state.
  (define (%run h invoke)
    (let ([entries (%entries-now h)])
      (unless (null? entries)
        (let ([caller (current-owner)])
          (let run ([entries entries])
            (let ([rest (call/1cc
                          (lambda (k)
                            (let ([at entries])
                              (with-exception-handler
                                (lambda (c)
                                  (cond
                                    [(cancelled? c) (raise-continuable c)]
                                    [(and (warning? c) (not (serious-condition? c))) (report c)]
                                    [else
                                     ;; An entry whose owner, or whose procedure's module, is
                                     ;; gone is skipped quietly. An entry that calls a module
                                     ;; that is gone, or a definition its loaded module no
                                     ;; longer defines, is a mistake to report.
                                     (unless (and (unloaded? c)
                                                  (or (eq? (unloaded-owner c) (%entry-owner (car at)))
                                                      (%unloaded-definition? (%entry-procedure (car at)))))
                                       (report c))
                                     (k (cdr at))]))
                                (lambda ()
                                  (let loop ([es entries])
                                    (unless (null? es)
                                      (let ([e (car es)])
                                        (set! at es)
                                        (cond
                                          [(not (owner-live? (%entry-owner e)))]
                                          [(eq? (%entry-owner e) caller) (invoke (%entry-procedure e))]
                                          [else (call-as-owner (%entry-owner e) (lambda () (invoke (%entry-procedure e))))])
                                        (loop (cdr es)))))
                                  '())))))])
              (unless (null? rest) (run rest)))))))))

(import %internals)

(define (%define-hook module name doc)
  (unless (or (not doc) (string? doc))
    (assertion-violation 'hooks:define-hook "not a documentation string" doc))
  (let* ([symbol (%full-symbol module name)]
         [h (or (hashtable-ref %hooks symbol #f)
                (letrec ([h (%make-hook symbol doc (owned:make symbol (lambda () (%refresh! h))))])
                  (hashtable-set! %hooks symbol h)
                  h))])
    (%hook-doc-set! h doc)
    (%refresh! h)
    (case-lambda
      [() (%run h (lambda (p) (p)))]
      [(a) (%run h (lambda (p) (p a)))]
      [(a b) (%run h (lambda (p) (p a b)))]
      [arguments (%run h (lambda (p) (apply p arguments)))])))

(define (%register! procedure module name)
  (hashtable-set! %by-procedure procedure (hashtable-ref %hooks (%full-symbol module name) #f)))

;; The hook is the defining module's changeable procedure, offered under
;; that module's prefix.
(define-syntax define-hook
  (lambda (x)
    (syntax-case x ()
      [(k id) (identifier? #'id) #'(k id #f)]
      [(k id doc)
       (identifier? #'id)
       #'(begin
           (define-public id (%define-hook (owner-name (current-owner)) 'id doc))
           (define-values () (begin (%register! id (owner-name (current-owner)) 'id) (values))))])))

(define (hook? v) (and (procedure? v) (hashtable-ref %by-procedure v #f) #t))

(define (%check-entry who proc depth)
  (unless (procedure? proc) (assertion-violation who "not a procedure" proc))
  (unless (real? depth) (assertion-violation who "not a real number" depth)))

(define add!
  (case-lambda
    [(h proc) (add! h proc 0)]
    [(h proc depth)
     (let ([st (%hook-of 'hooks:add! h)])
       (%check-entry 'hooks:add! proc depth)
       (%note-definer! proc)
       (call-with-cancellation-masked
         (lambda (restore)
           (owned:add! (%hook-set st) proc depth)
           (%changed! st proc))))]))

(define (remove! h proc)
  (let ([st (%hook-of 'hooks:remove! h)])
    (unless (procedure? proc) (assertion-violation 'hooks:remove! "not a procedure" proc))
    (call-with-cancellation-masked
      (lambda (restore)
        (owned:remove! (%hook-set st) proc)
        (%changed! st proc)))))

(define (%current-scope who)
  (or (scopes:current) (assertion-violation who "the current scope is #f")))

(define %main-thread (get-thread-id))

(define (%put-local! who h proc depth removal?)
  (unless (eqv? (get-thread-id) %main-thread)
    (assertion-violation who "only the main thread makes changes"))
  (let* ([st (%hook-of who h)] [s (%current-scope who)] [o (current-owner)])
    (unless (and o (owner-live? o)) (assertion-violation who "this code acts for no live owner" o))
    (call-with-cancellation-masked
      (lambda (restore)
        (%hook-localized?-set! st #t)
        (let* ([items (or (scopes:ref s (%hook-key st)) '())]
               [sequence (fx+ 1 (fold-left (lambda (n i) (fxmax n (%local-sequence i))) 0 items))])
          (scopes:set! s (%hook-key st)
            (cons (%make-local o proc depth removal? sequence)
                  (remp (lambda (i) (and (eq? (%local-owner i) o) (eq? (%local-procedure i) proc))) items))))))))

(define add-local!
  (case-lambda
    [(h proc) (add-local! h proc 0)]
    [(h proc depth)
     (%check-entry 'hooks:add-local! proc depth)
     (%note-definer! proc)
     (%put-local! 'hooks:add-local! h proc depth #f)]))

(define (remove-local! h proc)
  (unless (procedure? proc) (assertion-violation 'hooks:remove-local! "not a procedure" proc))
  (%put-local! 'hooks:remove-local! h proc 0 #t))

;; An entry whose owner has begun to unload is out of effect, whether or
;; not owned has dropped it yet; so is one whose procedure's module is
;; gone, which a call of the hook skips.
(define (entries h)
  (map %runner-of
       (filter (lambda (e) (and (owner-live? (%entry-owner e)) (not (%unloaded-definition? (%entry-procedure e)))))
               (%entries-now (%hook-of 'hooks:entries h)))))

(define (documentation h)
  (%hook-doc (%hook-of 'hooks:documentation h)))

;; Local entries are not in owned's sets, so they are dropped here, after
;; the owner's own clean-up.
(advice-add! owner-unloading
  (lambda (next owner)
    (next owner)
    (vector-for-each
      (lambda (h)
        (when (%hook-localized? h)
          (for-each
            (lambda (s)
              (scopes:set! s (%hook-key h)
                (remp (lambda (i) (eq? (%local-owner i) owner)) (scopes:ref s (%hook-key h)))))
            (scopes:holding (%hook-key h)))))
      (hashtable-values %hooks))))
