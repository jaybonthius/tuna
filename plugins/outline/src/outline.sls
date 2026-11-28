#!tuna
(import (buffers) (modes) (faces) (hooks) (options) (tables) (timers))

(define %self (current-owner))

(define-record-type (%entry %make-entry entry?)
  (sealed #t)
  (fields (immutable name entry-name) (immutable kind entry-kind) (immutable start entry-start)
          (immutable end entry-end) (immutable point entry-point) (immutable children entry-children)
          (immutable child-vector %entry-child-vector)))

(define (%blank? s) (for-all char-whitespace? (string->list s)))

(define (make-entry name kind start end point)
  (define who 'outline:make-entry)
  (unless (and (string? name) (not (%blank? name))) (assertion-violation who "not a name" name))
  (unless (symbol? kind) (assertion-violation who "not a kind" kind))
  (unless (and (fixnum? start) (fx>= start 0)) (assertion-violation who "not a position" start))
  (unless (and (fixnum? end) (fx>= end start)) (assertion-violation who "not a position at or after the start" end))
  (unless (and (fixnum? point) (fx<= start point end))
    (assertion-violation who "not a position from the start to the end" point))
  (%make-entry name kind start end point '() '#()))

(define (%with-children e children)
  (%make-entry (entry-name e) (entry-kind e) (entry-start e) (entry-end e) (entry-point e) children
               (list->vector children)))

(define (%holds? outer inner)
  (and (fx<= (entry-start outer) (entry-start inner)) (fx<= (entry-end inner) (entry-end outer))))

;; Siblings may share an edge, so one ends where the next starts.
(define (%in-order? entries)
  (or (null? entries) (null? (cdr entries))
      (and (fx<= (entry-end (car entries)) (entry-start (cadr entries))) (%in-order? (cdr entries)))))

(define (%entries? v) (and (list? v) (for-all entry? v)))

(define (make-parent entry children)
  (define who 'outline:make-parent)
  (unless (entry? entry) (assertion-violation who "not an entry" entry))
  (unless (%entries? children) (assertion-violation who "not a list of entries" children))
  (for-each (lambda (c) (unless (%holds? entry c) (assertion-violation who "a child is outside its parent" entry c)))
            children)
  (unless (%in-order? children) (assertion-violation who "the children are out of order or overlap" children))
  (%with-children entry children))

;; Sorted by start, the wider first, and stably, so an entry follows every
;; entry that holds it and equal ranges keep the order given.
(define (nest entries)
  (define who 'outline:nest)
  (unless (%entries? entries) (assertion-violation who "not a list of entries" entries))
  (for-each (lambda (e) (unless (null? (entry-children e)) (assertion-violation who "an entry has children" e)))
            entries)
  (let loop ([es (list-sort (lambda (a b)
                              (or (fx< (entry-start a) (entry-start b))
                                  (and (fx= (entry-start a) (entry-start b)) (fx> (entry-end a) (entry-end b)))))
                            entries)]
             [open '()]
             [roots '()])
    (cond
      [(and (pair? open) (or (null? es) (not (%holds? (caar open) (car es)))))
       (let ([done (%with-children (caar open) (reverse (cdar open)))] [rest (cdr open)])
         (if (null? rest)
             (loop es rest (cons done roots))
             (loop es (cons (cons (caar rest) (cons done (cdar rest))) (cdr rest)) roots)))]
      [(null? es) (reverse roots)]
      [else (loop (cdr es) (cons (list (car es)) open) roots)])))

(define-record-type (%kind %make-kind kind?)
  (sealed #t)
  (fields (immutable title kind-title) (immutable face kind-face)))

(define (make-kind title face)
  (unless (string? title) (assertion-violation 'outline:make-kind "not a title" title))
  (unless (symbol? face) (assertion-violation 'outline:make-kind "not a face" face))
  (%make-kind title face))

(tables:define-table kinds
  "Maps a kind of entry, a symbol, to an outline:make-kind that says how a viewer shows it: its group's title and its names' face.")

(define-record-type (%outline %make-outline outline?)
  (sealed #t)
  (fields (immutable buffer %outline-buffer) (immutable version %outline-version) (immutable roots %outline-roots)
          (immutable root-vector %outline-root-vector)))

(define (make-outline b version roots)
  (define who 'outline:make-outline)
  (unless (buffers:buffer? b) (assertion-violation who "not a buffer" b))
  (unless (and (fixnum? version) (fx<= 0 version (buffers:version b)))
    (assertion-violation who "not a version the buffer has reached" version))
  (unless (%entries? roots) (assertion-violation who "not a list of entries" roots))
  (unless (%in-order? roots) (assertion-violation who "the roots are out of order or overlap" roots))
  (%make-outline b version roots (list->vector roots)))

(define (%check-outline who o)
  (unless (outline? o) (assertion-violation who "not an outline" o)))

(define (buffer o)
  (%check-outline 'outline:buffer o)
  (%outline-buffer o))

(define (version o)
  (%check-outline 'outline:version o)
  (%outline-version o))

(define (roots o)
  (%check-outline 'outline:roots o)
  (%outline-roots o))

(define (paths o)
  (%check-outline 'outline:paths o)
  (let ([found (make-eq-hashtable)] [seen (make-hashtable string-hash string=?)])
    (let loop ([entries (%outline-roots o)] [prefix ""])
      (for-each (lambda (e)
                  (let* ([path (string-append prefix (entry-name e))] [n (hashtable-ref seen path 0)])
                    (hashtable-set! seen path (fx+ n 1))
                    (eq-hashtable-set! found e (if (fx= n 0) path (format "~a (~a)" path n)))
                    (loop (entry-children e) (string-append path "/"))))
                entries))
    found))

(define (walk o visit)
  (%check-outline 'outline:walk o)
  (unless (procedure? visit) (assertion-violation 'outline:walk "not a procedure" visit))
  (let loop ([entries (%outline-roots o)] [ancestors '()])
    (for-each (lambda (e)
                (visit e ancestors)
                (loop (entry-children e) (append ancestors (list e))))
              entries)))

;; A definition's start moves after text inserted at it, as text typed
;; before it is no part of it; its end and its name stay before.
(define (%mapper o)
  (let ([b (%outline-buffer o)] [v (%outline-version o)])
    (if (fx= v (buffers:version b))
        (values (lambda (p) p) (lambda (p) p))
        (values (lambda (p) (buffers:map-position-after b p v)) (lambda (p) (buffers:map-position b p v))))))

(define (%check-position who position)
  (unless (and (fixnum? position) (fx>= position 0))
    (assertion-violation who "not a position" position)))

(define (map o position)
  (%check-outline 'outline:map o)
  (%check-position 'outline:map position)
  (let-values ([(start-of at) (%mapper o)])
    (at position)))

;; Siblings are in order and end no later than the next starts, and
;; mapping keeps order, so each level is two binary searches: the last
;; sibling starting at or before the position, then the first of those
;; ending at or after it, which on a shared edge is the earlier.
(define (path o position)
  (%check-outline 'outline:path o)
  (%check-position 'outline:path position)
  (let-values ([(start-of end-of) (%mapper o)])
    (define (search lo hi ok?)
      (let loop ([lo lo] [hi hi] [found #f])
        (if (fx> lo hi)
            found
            (let* ([mid (fxsrl (fx+ lo hi) 1)] [answer (ok? mid)])
              (cond
                [(eq? answer 'lost) 'lost]
                [answer (loop (fx+ mid 1) hi mid)]
                [else (loop lo (fx- mid 1) found)])))))
    (define (holder siblings)
      (let ([last-start (search 0 (fx- (vector-length siblings) 1)
                                (lambda (k)
                                  (let ([s (start-of (entry-start (vector-ref siblings k)))])
                                    (if s (fx<= s position) 'lost))))])
        (cond
          [(or (not last-start) (eq? last-start 'lost)) last-start]
          [else
           (let loop ([lo 0] [hi last-start] [found #f])
             (if (fx> lo hi)
                 (and found (vector-ref siblings found))
                 (let* ([mid (fxsrl (fx+ lo hi) 1)] [e (end-of (entry-end (vector-ref siblings mid)))])
                   (cond
                     [(not e) 'lost]
                     [(fx>= e position) (loop lo (fx- mid 1) mid)]
                     [else (loop (fx+ mid 1) hi found)]))))])))
    (let loop ([siblings (%outline-root-vector o)] [acc '()])
      (let ([e (holder siblings)])
        (cond
          [(eq? e 'lost) #f]
          [(not e) (reverse acc)]
          [else (loop (%entry-child-vector e) (cons e acc))])))))

(hooks:define-hook sources
  "Called with a buffer, current, in order, until an entry returns an outline of it made with outline:make-outline; an entry returns #f when it has no answer for the buffer.")

(hooks:define-hook updated
  "Called with a buffer and its new outline when an outline was made that differs from the last by its entries' names, kinds or ranges. An entry must not pause.")

(options:define-option idle-delay 0.5 (lambda (v) (and (real? v) (>= v 0) (finite? v) #t))
  "Seconds Tuna must have been idle, counted from the last input, before a stale outline of a buffer read with outline:cached since it was made is made again."
  (lambda (v) (%restart-idle-timer!)))

;; The work of making a buffer's outline runs in a task of the plugin's
;; own that every caller waits for, so one caller's cancel leaves the
;; others their answer. Work an idle remake started is kept: no caller
;; leaving cancels it.
(define-record-type %work
  (sealed #t)
  (fields (mutable task) (mutable waiters) (mutable kept?)))

(define-record-type %state
  (sealed #t)
  (fields buffer (mutable answered?) (mutable outline) (mutable asked) (mutable mode) (mutable sources)
          (mutable made-forgets) (mutable forgets) (mutable read?) (mutable reported) (mutable work)))

(define %states (make-ephemeron-eq-hashtable))

(define (%state-of b)
  (or (eq-hashtable-ref %states b #f)
      (let ([s (make-%state b #f #f #f #f '() 0 0 #f '() #f)])
        (eq-hashtable-set! %states b s)
        s)))

(define (%sources-of b) (buffers:with-buffer b (hooks:entries sources)))

(define (%same-procedures? a b)
  (cond
    [(null? a) (null? b)]
    [(null? b) #f]
    [else (and (eq? (car a) (car b)) (%same-procedures? (cdr a) (cdr b)))]))

(define (%stale? s)
  (let ([b (%state-buffer s)])
    (or (not (%state-answered? s))
        (not (fx= (%state-made-forgets s) (%state-forgets s)))
        (not (eqv? (%state-asked s) (buffers:version b)))
        (not (eq? (%state-mode s) (modes:major-mode b)))
        (not (%same-procedures? (%state-sources s) (%sources-of b))))))

(define (%needs-remake? s)
  (or (%stale? s)
      (let ([o (%state-outline s)]) (and o (not (fx= (%outline-version o) (buffers:version (%state-buffer s))))))))

(define (%ask-sources s b entries)
  (let loop ([entries entries])
    (if (null? entries)
        #f
        (let* ([entry (car entries)]
               [answer (guard (c [(cancelled? c) (raise c)]
                                 [else
                                  (unless (memq entry (%state-reported s))
                                    (%state-reported-set! s (cons entry (%state-reported s)))
                                    (report c))
                                  'raised])
                         (let ([o (buffers:with-buffer b (entry b))])
                           (unless (or (not o) (and (outline? o) (eq? (%outline-buffer o) b)))
                             (assertion-violation 'outline:sources "a source returned neither an outline of the buffer nor #f" o))
                           o))])
          (unless (eq? answer 'raised)
            (%state-reported-set! s (remq entry (%state-reported s))))
          (if (outline? answer) answer (loop (cdr entries)))))))

(define (%entries-now o)
  (let-values ([(start-of end-of) (%mapper o)])
    (let loop ([entries (%outline-roots o)] [depth 0] [acc '()])
      (if (null? entries)
          acc
          (let* ([e (car entries)] [start (start-of (entry-start e))] [end (end-of (entry-end e))])
            (and start end
                 (let ([acc (loop (entry-children e) (fx+ depth 1)
                                  (cons (list depth (entry-name e) (entry-kind e) start end) acc))])
                   (and acc (loop (cdr entries) depth acc)))))))))

(define (%same-outline? a b)
  (and a
       (let ([now-a (%entries-now a)] [now-b (%entries-now b)])
         (and now-a now-b (equal? now-a now-b)))))

;; A read is answered by an outline that is current, so one that went
;; stale while it was made leaves the read standing.
(define (%record! s o version mode entries forgets)
  (let ([b (%state-buffer s)] [old (%state-outline s)])
    (%state-answered?-set! s #t)
    (%state-outline-set! s o)
    (%state-asked-set! s version)
    (%state-mode-set! s mode)
    (%state-sources-set! s entries)
    (%state-made-forgets-set! s forgets)
    (unless (%stale? s) (%state-read?-set! s #f))
    (when (and o (not (%same-outline? old o)))
      (updated b o))))

(define (%end-work! s w outcome)
  (when (eq? (%state-work s) w)
    (%state-work-set! s #f))
  (let ([waiters (%work-waiters w)])
    (%work-waiters-set! w '())
    (for-each (lambda (resume) (resume outcome)) waiters)))

;; Callers wait on the work, so whatever ends it ends their wait. A
;; dynamic-wind would end it at the sources' first pause.
(define (%run-work s w)
  (%end-work! s w
    (guard (c [(cancelled? c) (lambda () #f)]
              [else (report c) (lambda () #f)])
      (let* ([b (%state-buffer s)] [version (buffers:version b)] [mode (modes:major-mode b)]
             [forgets (%state-forgets s)] [entries (%sources-of b)] [o (%ask-sources s b entries)])
        (when (buffers:live? b)
          (%record! s o version mode entries forgets))
        (lambda () o))))
  (%remake-if-due! s))

(define (%start-work! s kept?)
  (let ([w (make-%work #f '() kept?)])
    (%state-work-set! s w)
    (%work-task-set! w (call-as-owner %self (lambda () (spawn-task (lambda (restore) (%run-work s w))))))
    w))

(define (%leave! s w resume)
  (%work-waiters-set! w (remq resume (%work-waiters w)))
  (when (and (null? (%work-waiters w)) (not (%work-kept? w)) (eq? (%state-work s) w))
    (%state-work-set! s #f)
    (cancel-task (%work-task w))))

(define (%await s)
  (let ([w (or (%state-work s) (%start-work! s #f))] [me #f])
    (guard (c [(cancelled? c) (%leave! s w me) (raise c)])
      (suspend
        (lambda (resume)
          (set! me resume)
          (%work-waiters-set! w (cons resume (%work-waiters w))))))))

(define (%check-live who b)
  (unless (buffers:buffer? b) (assertion-violation who "not a buffer" b))
  (unless (buffers:live? b) (assertion-violation who "not a live buffer" b)))

(define (get b)
  (%check-live 'outline:get b)
  (let ([s (%state-of b)])
    (if (%stale? s) (%await s) (%state-outline s))))

(define (cached b)
  (unless (buffers:buffer? b) (assertion-violation 'outline:cached "not a buffer" b))
  (and (buffers:live? b)
       (let ([s (%state-of b)])
         (%state-read?-set! s #t)
         (%state-outline s))))

;; Tuna has been idle idle-delay since the last input, so the idle pass
;; of this period has run and will not run again until the next.
(define (%idle-past-delay?)
  (let ([t (timers:idle-seconds)]) (and t (>= t (idle-delay)))))

(define (%remake-if-due! s)
  (when (and (%state-read? s) (not (%state-work s)) (buffers:live? (%state-buffer s)) (%stale? s) (%idle-past-delay?))
    (%start-work! s #t)))

(define (%remake-read!)
  (vector-for-each
    (lambda (s)
      (when (and (%state-read? s) (not (%state-work s)) (buffers:live? (%state-buffer s)) (%needs-remake? s))
        (%start-work! s #t)))
    (hashtable-values %states)))

(define %idle-timer #f)

(define (%restart-idle-timer!)
  (when %idle-timer (timers:cancel! %idle-timer))
  (set! %idle-timer (call-as-owner %self (lambda () (timers:run-when-idle (idle-delay) %remake-read!)))))

(define (forget! b)
  (unless (buffers:buffer? b) (assertion-violation 'outline:forget! "not a buffer" b))
  (let ([s (eq-hashtable-ref %states b #f)])
    (when s
      (%state-forgets-set! s (fx+ (%state-forgets s) 1))
      (%remake-if-due! s))))

(define (%killed b) (eq-hashtable-delete! %states b))

(record-writer (record-type-descriptor %entry)
  (lambda (e p wr) (format p "#<entry ~a ~s>" (entry-kind e) (entry-name e))))

(record-writer (record-type-descriptor %outline)
  (lambda (o p wr) (format p "#<outline ~a>" (buffers:name (%outline-buffer o)))))

(for-each (lambda (k) (tables:set! kinds (car k) (make-kind (cadr k) (caddr k))))
  (list (list 'class "Classes" faces:type) (list 'struct "Structs" faces:type) (list 'interface "Interfaces" faces:type)
        (list 'enum "Enums" faces:type) (list 'module "Modules" faces:type) (list 'namespace "Namespaces" faces:type)
        (list 'package "Packages" faces:type) (list 'function "Functions" faces:function)
        (list 'constructor "Constructors" faces:function) (list 'macro "Macros" faces:function)
        (list 'event "Events" faces:function) (list 'method "Methods" faces:function.method)
        (list 'property "Properties" faces:variable.member) (list 'field "Fields" faces:variable.member)
        (list 'variable "Variables" faces:variable) (list 'constant "Constants" faces:constant)
        (list 'heading "Headings" faces:markup.heading)))
(%restart-idle-timer!)
(hooks:add! buffers:killed %killed)
