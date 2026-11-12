#!tuna
(import (buffers) (document) (web) (haml))

(define-option drawn-margin 0.5 (lambda (v) (and (real? v) (finite? v) (>= v 0)))
  "How many view heights a view draws above and below the lines in view.")
(define-option scroll-margin 0 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many lines a view keeps between the primary cursor and its top and bottom edges.")
(define-option scroll-conservatively 0 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How far a view scrolls line by line to bring the primary cursor back into view before it centres it instead.")
(define-option wrap-lines #t boolean?
  "Whether a line longer than the view wraps onto several screen lines.")

(define-table span-properties
  "Maps a key of a span's value to a procedure that returns attributes for the span's element.")

(define-enumeration align (top center bottom) %alignments)

(module %internals
  (check-main-thread check-view check-cursor check-node check-option check-position check-live-buffer showing
   current-view make-new-view! find-view bound-buffer show-buffer! drop-view! with-view-bound
   view-record? view-record-dropped? view-record-id view-record-cursors view-record-cursors-set! view-record-top
   view-record-folds-set! view-record-narrowing-set!
   cursor-record? cursor-record-view cursor-record-goal cursor-record-goal-set!
   spot-position point-of mark-of set-cursor-spots! move-point! add-cursor-at! primary-moved! mark-dirty!
   bounds-of live-folds add-fold! narrow-view! stop-after stop-before
   set-view-option! remove-view-option! state-entry view-record-states view-record-states-set!
   scroll-to-line! scrolled draw-view current-context context-view in-line? make-context children-html drawing?
   atom-view-of keymaps-at note-edit note-kill after-batch scroll-report
   face-attributes title-attributes)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  ;; Positions a view keeps are anchors while it shows a live buffer, and
  ;; plain numbers while it waits for one, as views restored from saved
  ;; data do until their buffer is made.
  (define-record-type view-record
    (sealed #t)
    (fields id (mutable name) (mutable buffer) (mutable cursors)
            (mutable top) (mutable offset) (mutable count) (mutable line-height) (mutable drawn)
            (mutable placement) (mutable place-at) (mutable place-align) (mutable place-offset)
            (mutable moved?) (mutable folds) (mutable narrowing) (mutable options) (mutable states)
            (mutable saved?) (mutable host) (mutable dropped?)))

  (define-record-type cursor-record
    (sealed #t)
    (fields view (mutable point) (mutable mark) (mutable goal)))

  (define-record-type view-option
    (sealed #t)
    (fields option value owner))

  (define current-view (make-thread-parameter #f))

  (define by-id (make-eqv-hashtable))
  (define views '())
  (define by-buffer (make-eq-hashtable))
  (define next-id 1)
  (define dirty? #f)

  (define (mark-dirty!) (set! dirty? #t))

  (define (check-view who v)
    (unless (view-record? v)
      (assertion-violation who "not a view" v))
    (when (view-record-dropped? v)
      (assertion-violation who "a dropped view" v))
    (check-main-thread who))

  (define (check-cursor who c)
    (unless (cursor-record? c)
      (assertion-violation who "not a cursor" c))
    (when (view-record-dropped? (cursor-record-view c))
      (assertion-violation who "a cursor of a dropped view" c))
    (check-main-thread who))

  (define (check-live-buffer who b)
    (unless (and (buffers:buffer? b) (buffers:live? b))
      (assertion-violation who "not a live buffer" b)))

  (define (check-node who n)
    (unless (document:node? n)
      (assertion-violation who "not a node" n)))

  (define (check-option who o)
    (unless (option? o)
      (assertion-violation who "not an option" o)))

  (define (find-view id) (hashtable-ref by-id id #f))

  ;; This module defines find, so its own code searches lists with this.
  (define (find-first ok? ls)
    (let ([m (memp ok? ls)]) (and m (car m))))

  (define (add-view! v)
    (let ([all (append views (list v))] [b (view-record-buffer v)])
      (with-interrupts-disabled
        (hashtable-set! by-id (view-record-id v) v)
        (set! views all)
        (when b (hashtable-update! by-buffer b (lambda (vs) (cons v vs)) '()))
        (when (fx>= (view-record-id v) next-id)
          (set! next-id (fx+ (view-record-id v) 1)))
        (set! dirty? #t)))
    v)

  (define (spot-position s) (if (fixnum? s) s (buffers:anchor-position s)))

  (define (make-spot b p after?)
    (cond
      [(not b) p]
      [after? (buffers:anchor-after b p)]
      [else (buffers:anchor b p)]))

  (define (move-spot s b p after?)
    (if (fixnum? s)
        (make-spot b p after?)
        (begin (buffers:set-anchor! s p) s)))

  (define (buffer-length b) (document:length (buffers:document b)))

  (define (view-length v)
    (let ([b (view-record-buffer v)]) (if b (buffer-length b) 0)))

  (define (check-position who v p)
    (unless (and (fixnum? p) (fx<= 0 p (view-length v)))
      (assertion-violation who "not a position in the view's buffer" p)))

  (define (bounds-of v)
    (let ([n (view-record-narrowing v)])
      (if n
          (values (spot-position (car n)) (spot-position (cdr n)))
          (values 0 (view-length v)))))

  (define (stop-within b lo hi p)
    (let* ([p (fxmax lo (fxmin hi p))] [s (buffers:stop b p)])
      (cond
        [(and s (fx<= lo s hi)) s]
        [(let ([q (buffers:next-stop b p)]) (and q (fx<= q hi) q))]
        [(let ([q (buffers:previous-stop b p)]) (and q (fx>= q lo) q))]
        [else p])))

  (define (point-of c) (spot-position (cursor-record-point c)))

  (define (mark-of c)
    (let ([m (cursor-record-mark c)]) (and m (spot-position m))))

  (define (set-cursor-spots! c point mark)
    (let ([b (view-record-buffer (cursor-record-view c))])
      (cursor-record-point-set! c (move-spot (cursor-record-point c) b point #f))
      (cursor-record-mark-set! c
        (and mark (let ([m (cursor-record-mark c)])
                    (if m (move-spot m b mark #f) (make-spot b mark #f)))))
      (mark-dirty!)))

  (define (primary-moved! v) (view-record-moved?-set! v #t))

  ;; A view starts with nothing measured: it guesses this many lines in
  ;; view until the first report, and draws no spacers, since their height
  ;; is the lines' measured average.
  (define unmeasured-lines 50)

  (define (reset-view! v b)
    (let* ([n (if b (buffer-length b) 0)]
           [cursors (list (make-cursor-record v (make-spot b (if b (stop-within b 0 n 0) 0) #f) #f #f))]
           [top (make-spot b 0 #f)] [at (make-spot b 0 #f)])
      (with-interrupts-disabled
        (view-record-cursors-set! v cursors)
        (view-record-top-set! v top)
        (view-record-offset-set! v 0)
        (view-record-drawn-set! v #f)
        (view-record-placement-set! v (fx+ (view-record-placement v) 1))
        (view-record-place-at-set! v at)
        (view-record-place-align-set! v 'top)
        (view-record-place-offset-set! v 0)
        (view-record-moved?-set! v #f)
        (view-record-folds-set! v '())
        (view-record-narrowing-set! v #f)
        (view-record-states-set! v '())
        (set! dirty? #t))))

  (define (make-new-view! id b name)
    (let ([v (make-view-record (or id next-id) name b '() 0 0 unmeasured-lines #f #f 0 0 'top 0 #f '() #f '() '() #f #f #f)])
      (reset-view! v b)
      (add-view! v)))

  (define (set-shown-buffer! v b)
    (let ([old (view-record-buffer v)])
      (unless (eq? old b)
        (with-interrupts-disabled
          (when old
            (let ([vs (remq v (hashtable-ref by-buffer old '()))])
              (if (null? vs) (hashtable-delete! by-buffer old) (hashtable-set! by-buffer old vs))))
          (when b (hashtable-update! by-buffer b (lambda (vs) (cons v vs)) '()))
          (view-record-buffer-set! v b)))))

  (define (show-buffer! v b)
    (view-record-name-set! v (buffers:name b))
    (set-shown-buffer! v b)
    (reset-view! v b))

  (define (drop-view! v)
    (let ([all (remq v views)])
      (with-interrupts-disabled
        (set-shown-buffer! v #f)
        (hashtable-delete! by-id (view-record-id v))
        (set! views all)
        (view-record-dropped?-set! v #t)
        (set! dirty? #t)))
    (let-values ([(keys vs) (hashtable-entries copies)])
      (vector-for-each (lambda (k c) (when (eq? c v) (hashtable-delete! copies k))) keys vs)))

  ;; A view whose buffer is gone keeps its positions as numbers, so a
  ;; buffer made again under the name shows them.
  (define (unbind! v)
    (define (number s) (and s (spot-position s)))
    (let* ([cs (view-record-cursors v)]
           [points (map (lambda (c) (number (cursor-record-point c))) cs)]
           [marks (map (lambda (c) (number (cursor-record-mark c))) cs)]
           [top (number (view-record-top v))]
           [at (number (view-record-place-at v))]
           [folds (map (lambda (f) (cons (number (car f)) (number (cdr f)))) (view-record-folds v))]
           [narrowing (let ([r (view-record-narrowing v)]) (and r (cons (number (car r)) (number (cdr r)))))])
      (commit-positions! v #f cs points marks top at folds narrowing)))

  (define (bind! v b)
    (let* ([n (buffer-length b)]
           [spot (lambda (s after?) (make-spot b (fxmin n (spot-position s)) after?))]
           [narrowing (let ([r (view-record-narrowing v)]) (and r (cons (spot (car r) #f) (spot (cdr r) #t))))]
           [lo (if narrowing (spot-position (car narrowing)) 0)]
           [hi (if narrowing (spot-position (cdr narrowing)) n)]
           [cs (view-record-cursors v)]
           [points (map (lambda (c) (make-spot b (stop-within b lo hi (spot-position (cursor-record-point c))) #f)) cs)]
           [marks (map (lambda (c) (let ([m (cursor-record-mark c)]) (and m (spot m #f)))) cs)]
           [top (spot (view-record-top v) #f)]
           [at (spot (view-record-place-at v) #f)]
           [folds (map (lambda (f) (cons (spot (car f) #t) (spot (cdr f) #f))) (view-record-folds v))])
      (commit-positions! v b cs points marks top at folds narrowing)))

  ;; A quit leaves a view showing its old buffer or its new one, never
  ;; positions of both.
  (define (commit-positions! v b cs points marks top at folds narrowing)
    (with-interrupts-disabled
      (for-each (lambda (c p m) (cursor-record-point-set! c p) (cursor-record-mark-set! c m)) cs points marks)
      (view-record-top-set! v top)
      (view-record-place-at-set! v at)
      (view-record-folds-set! v folds)
      (view-record-narrowing-set! v narrowing)
      (view-record-states-set! v '())
      (set-shown-buffer! v b)))

  (define (bound-buffer v)
    (let ([b (view-record-buffer v)])
      (if (and b (buffers:live? b))
          b
          (begin
            (when b (unbind! v))
            (let ([found (buffers:find (view-record-name v))])
              (and found (begin (bind! v found) found)))))))

  (define (live-folds v)
    (let* ([folds (view-record-folds v)]
           [live (filter (lambda (f) (fx< (spot-position (car f)) (spot-position (cdr f)))) folds)])
      (unless (fx= (length live) (length folds))
        (view-record-folds-set! v live)
        (mark-dirty!))
      live))

  (define (fold-holding v p)
    (find-first (lambda (f) (fx< (spot-position (car f)) p (spot-position (cdr f)))) (live-folds v)))

  (define (open-folds-at-cursors! v)
    (unless (null? (view-record-folds v))
      (let ([points (map point-of (view-record-cursors v))])
        (let ([kept (filter (lambda (f)
                              (let ([s (spot-position (car f))] [e (spot-position (cdr f))])
                                (not (exists (lambda (p) (fx< s p e)) points))))
                            (live-folds v))])
          (unless (fx= (length kept) (length (view-record-folds v)))
            (view-record-folds-set! v kept)
            (mark-dirty!))))))

  (define (merge-cursors! v)
    (let loop ([cs (view-record-cursors v)] [seen '()] [kept '()])
      (cond
        [(null? cs)
         (unless (fx= (length kept) (length (view-record-cursors v)))
           (view-record-cursors-set! v (reverse kept)))]
        [(memv (point-of (car cs)) seen) (loop (cdr cs) seen kept)]
        [else (loop (cdr cs) (cons (point-of (car cs)) seen) (cons (car cs) kept))])))

  ;; A value's owner takes it back when it unloads, as the core takes
  ;; back the owner's own option settings.
  (define owners-with-actions '())

  (define (set-view-option! who v option value owner)
    (guard (c [(and (message-condition? c) (not (quit-condition? c)))
               (apply assertion-violation who (condition-message c)
                      (if (irritants-condition? c) (condition-irritants c) '()))])
      (with-options ([option value]) #f))
    (when (and owner (not (member owner owners-with-actions)))
      (on-unload (lambda () (take-back-options! owner)))
      (set! owners-with-actions (cons owner owners-with-actions)))
    (view-record-options-set! v
      (append (remp (lambda (e) (eq? (view-option-option e) option)) (view-record-options v))
              (list (make-view-option option value owner))))
    (mark-dirty!))

  (define (take-back-options! owner)
    (set! owners-with-actions (remove owner owners-with-actions))
    (for-each
      (lambda (v)
        (view-record-options-set! v (remp (lambda (e) (equal? (view-option-owner e) owner)) (view-record-options v))))
      views)
    (mark-dirty!))

  (define (remove-view-option! v option)
    (view-record-options-set! v (remp (lambda (e) (eq? (view-option-option e) option)) (view-record-options v)))
    (mark-dirty!))

  (define (call-with-view-options v thunk)
    (let loop ([options (view-record-options v)])
      (if (null? options)
          (thunk)
          (with-options ([(view-option-option (car options)) (view-option-value (car options))])
            (loop (cdr options))))))

  ;; Node state is kept against an anchor right after the node's opening,
  ;; which reports itself deleted once the node is.
  (define (state-entry v node)
    (let ([b (bound-buffer v)] [at (fx+ (document:node-start node) 1)])
      (unless (and b (fx<= at (buffer-length b)))
        (assertion-violation 'views:node-state "not a node of the view's buffer" node))
      (let ([live (filter (lambda (e) (not (buffers:anchor-deleted? (car e)))) (view-record-states v))])
        (view-record-states-set! v live)
        (values b at (find-first (lambda (e) (fx= (buffers:anchor-position (car e)) at)) live)))))

  (define (line-limits doc lo hi) (values (document:line doc lo) (document:line doc hi)))

  (define (top-line v doc first last)
    (fxmax first (fxmin last (document:line doc (spot-position (view-record-top v))))))

  ;; Emacs's window_scroll_margin with maximum-scroll-margin 0.25: never
  ;; more than a quarter of the lines in view, so a short view still moves
  ;; its cursor.
  (define (clamped-margin margin count)
    (fxmax 0 (fxmin margin (fxquotient (fx- count 1) 2) (fxquotient count 4))))

  (define (set-top! v doc line)
    (view-record-top-set! v (move-spot (view-record-top v) (view-record-buffer v) (document:line-start doc line) #f)))

  ;; A placement's number and place change together, so no client applies
  ;; a number with the place before it.
  (define (place! v doc line align)
    (let ([at (make-spot (view-record-buffer v) (document:line-start doc line) #f)])
      (with-interrupts-disabled
        (view-record-placement-set! v (fx+ (view-record-placement v) 1))
        (view-record-place-at-set! v at)
        (view-record-place-align-set! v align)
        (view-record-place-offset-set! v 0)
        (view-record-moved?-set! v #f)
        (set! dirty? #t))))

  (define (scroll-to-line! v doc line align)
    (let-values ([(lo hi) (bounds-of v)])
      (let-values ([(first last) (line-limits doc lo hi)])
        (let* ([line (fxmax first (fxmin last line))] [n (view-record-count v)])
          (set-top! v doc
            (fxmax first (fxmin last (case align
                                       [(top) line]
                                       [(center) (fx- line (fxquotient n 2))]
                                       [else (fx- line (fx- n 1))]))))
          (place! v doc line align)))))

  (define (follow-cursor! v b doc)
    (view-record-moved?-set! v #f)
    (let-values ([(lo hi) (bounds-of v)])
      (let-values ([(first last) (line-limits doc lo hi)])
        (let* ([pl (document:line doc (point-of (car (view-record-cursors v))))]
               [t (top-line v doc first last)]
               [n (view-record-count v)]
               [lv (fxmin last (fx+ t (fx- n 1)))]
               [m (clamped-margin (scroll-margin) n)]
               [low (if (fx= t first) first (fx+ t m))]
               [high (if (fx= lv last) last (fx- lv m))]
               [c (scroll-conservatively)])
          (cond
            [(fx< pl low)
             (let ([needed (fx- low pl)])
               (if (fx<= needed c)
                   (let ([t (fxmax first (fx- t needed))]) (set-top! v doc t) (place! v doc t 'top))
                   (scroll-to-line! v doc pl 'center)))]
            [(fx> pl high)
             (let ([needed (fx- pl high)])
               (if (fx<= needed c)
                   (let ([t (fxmin last (fx+ t needed))]) (set-top! v doc t) (place! v doc t 'top))
                   (scroll-to-line! v doc pl 'center)))])))))

  ;; A report makes the reported place the view's placement without a new
  ;; number, so a client that has applied none shows where the others are.
  (define (scrolled v top offset last)
    (let ([b (bound-buffer v)])
      (if (not b)
          (view-record-top-set! v top)
          (let* ([doc (buffers:document b)] [t (document:line doc top)] [n (fxmax 1 (fx+ (fx- (document:line doc last) t) 1))]
                 [top (make-spot b (document:line-start doc t) #f)] [at (make-spot b (document:line-start doc t) #f)])
            (with-interrupts-disabled
              (view-record-top-set! v top)
              (view-record-offset-set! v offset)
              (view-record-count-set! v n)
              (view-record-place-at-set! v at)
              (view-record-place-align-set! v 'top)
              (view-record-place-offset-set! v offset)
              (view-record-moved?-set! v #f))
            (cursor-into-view! v b doc t n)))
      (mark-dirty!)))

  (define (cursor-into-view! v b doc t n)
    (let-values ([(lo hi) (bounds-of v)])
      (let-values ([(first last) (line-limits doc lo hi)])
        (let* ([c (car (view-record-cursors v))]
               [p (point-of c)]
               [pl (document:line doc p)]
               [lv (fxmin last (fx+ t (fx- n 1)))]
               [m (clamped-margin (scroll-margin) n)]
               [low (fxmin lv (if (fx= t first) first (fx+ t m)))]
               [high (fxmax low (if (fx= lv last) last (fx- lv m)))]
               [target (cond [(fx< pl low) low] [(fx> pl high) high] [else #f])])
          (when target
            (let* ([chars (document:unit characters)]
                   [column (or (cursor-record-goal c)
                               (fx- (document:offset doc p chars) (document:offset doc (document:line-start doc pl) chars)))]
                   [start (document:offset doc (document:line-start doc target) chars)]
                   [end (if (fx< target (document:line doc (document:length doc)))
                            (fx- (document:offset doc (document:line-start doc (fx+ target 1)) chars) 1)
                            (document:offset doc (document:length doc) chars))]
                   [q (document:position doc (fxmin (fx+ start column) end) chars)])
              (set-cursor-spots! c (stop-within b lo hi q) (mark-of c))))))))

  (define current-context (make-thread-parameter #f))
  (define in-line? (make-thread-parameter #f))
  (define drawing (make-thread-parameter '()))

  (define (drawing? v) (memq v (drawing)))

  (define-record-type (context new-context context?)
    (sealed #t)
    (fields view doc lo hi ws we root cursors spans longest folds (mutable shown) line-ids))

  (define-record-type span-entry
    (sealed #t)
    (fields start end rank open before after replace))

  (define-record-type span-style
    (sealed #t)
    (fields open before after replace))

  (define-record-type insertion
    (sealed #t)
    (fields at order html span))

  (define (fold-ranges v)
    (list-sort (lambda (a b) (fx< (car a) (car b)))
               (map (lambda (f) (cons (spot-position (car f)) (spot-position (cdr f)))) (live-folds v))))

  (define (cursor-points v)
    (let loop ([cs (view-record-cursors v)] [primary? #t] [acc '()])
      (if (null? cs)
          (list-sort (lambda (a b) (fx< (car a) (car b))) acc)
          (loop (cdr cs) #f (cons (cons (point-of (car cs)) primary?) acc)))))

  (define (escape-attribute s p)
    (string-for-each
      (lambda (c)
        (case c
          [(#\&) (put-string p "&amp;")]
          [(#\<) (put-string p "&lt;")]
          [(#\>) (put-string p "&gt;")]
          [(#\") (put-string p "&quot;")]
          [else (put-char p c)]))
      s))

  (define (attribute-name? s)
    (and (string? s) (fx> (string-length s) 0)
         (for-all (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_ #\: #\.))))
                  (string->list s))))

  (define (attribute-text v)
    (cond
      [(string? v) v]
      [(symbol? v) (symbol->string v)]
      [(number? v) (number->string v)]
      [else #f]))

  (define (report-as module c)
    (if (and module (member module (loaded-modules)))
        (as-module module (report c))
        (report c)))

  ;; Buffers offers no kind's owner, so the module is read from the name
  ;; define-kind gives a kind, a/b:kind for (a b); a kind named another
  ;; way may be reported as the wrong module's.
  (define (module-of-name name)
    (let* ([s (symbol->string name)]
           [colon (let loop ([i (fx- (string-length s) 1)])
                    (cond [(fx< i 0) #f] [(char=? (string-ref s i) #\:) i] [else (loop (fx- i 1))]))])
      (and colon
           (let loop ([part '()] [parts '()] [cs (string->list (substring s 0 colon))])
             (define (word) (string->symbol (list->string (reverse part))))
             (cond
               [(null? cs) (reverse (cons (word) parts))]
               [(char=? (car cs) #\/) (loop '() (cons (word) parts) (cdr cs))]
               [else (loop (cons (car cs) part) parts (cdr cs))])))))

  ;; Attribute names come from users' tables, so the element is written
  ;; here rather than by haml, which takes names only as written in code.
  (define (span-open value malformed!)
    (let loop ([value (if (list? value) value '())] [classes '()] [others '()])
      (cond
        [(null? value)
         (call-with-string-output-port
           (lambda (p)
             (put-string p "<span")
             (unless (null? classes)
               (put-string p " class=\"")
               (let ([classes (reverse classes)])
                 (escape-attribute (car classes) p)
                 (for-each (lambda (c) (put-char p #\space) (escape-attribute c p)) (cdr classes)))
               (put-char p #\"))
             (for-each
               (lambda (a)
                 (put-char p #\space)
                 (put-string p (car a))
                 (when (string? (cdr a))
                   (put-string p "=\"")
                   (escape-attribute (cdr a) p)
                   (put-char p #\")))
               (reverse others))
             (put-char p #\>)))]
        [(and (pair? (car value)) (symbol? (caar value)) (table-ref span-properties (caar value) #f))
         => (lambda (proc)
              (let add ([as (let ([as (guard (c [(not (quit-condition? c)) (report c) '()])
                                        (proc (cdar value)))])
                              (if (and (list? as) (for-all (lambda (a) (and (pair? a) (attribute-name? (car a)))) as))
                                  as
                                  (begin (malformed! (caar value) as) (if (list? as) as '()))))]
                        [classes classes] [others others])
                (cond
                  [(null? as) (loop (cdr value) classes others)]
                  [(not (and (pair? (car as)) (attribute-name? (caar as)))) (add (cdr as) classes others)]
                  [(string=? (caar as) "class")
                   (let ([t (attribute-text (cdar as))])
                     (add (cdr as) (if t (cons t classes) classes) others))]
                  [else
                   (let ([t (if (eq? (cdar as) #t) #t (attribute-text (cdar as)))]
                         [others (remp (lambda (o) (string=? (car o) (caar as))) others)])
                     (add (cdr as) classes (if t (cons (cons (caar as) t) others) others)))])))]
        [else (loop (cdr value) classes others)])))

  (define (value-ref value key)
    (and (list? value)
         (let ([e (find-first (lambda (e) (and (pair? e) (eq? (car e) key))) value)]) (and e (cdr e)))))

  (define (window-spans b v ws we)
    (let ([entries
           (let ([styles (make-hashtable equal-hash equal?)] [reported '()])
             (define (malformed! key as)
               (unless (memq key reported)
                 (set! reported (cons key reported))
                 (report (condition (make-who-condition 'views:span-properties)
                                    (make-message-condition "not a list of attribute names and values")
                                    (make-irritants-condition (list key as))))))
             (define (style value)
               (or (hashtable-ref styles value #f)
                   (let ([style (make-span-style (let ([open (span-open value malformed!)]) (and (not (string=? open "<span>")) (raw-html open)))
                                                 (value-ref value 'before) (value-ref value 'after) (value-ref value 'replace))])
                     (hashtable-set! styles value style)
                     style)))
             (let loop ([layers (buffers:layers b v)] [rank 0] [acc '()])
               (if (null? layers)
                   acc
                   (loop (cdr layers) (fx+ rank 1)
                         (fold-left
                           (lambda (acc s)
                             (let ([style (style (caddr s))])
                               (cons (make-span-entry (car s) (cadr s) rank (span-style-open style) (span-style-before style)
                                                      (span-style-after style) (span-style-replace style))
                                     acc)))
                           acc (buffers:spans (car layers) ws we))))))]
          [regions
           (fold-left
             (lambda (acc c)
               (let ([p (point-of c)] [m (mark-of c)])
                 (if (and m (not (fx= p m)))
                     (cons (make-span-entry (fxmin p m) (fxmax p m) -1 region-open #f #f #f) acc)
                     acc)))
             '() (view-record-cursors v))])
      (list->vector (list-sort (lambda (a b) (fx< (span-entry-start a) (span-entry-start b)))
                               (append regions entries)))))

  (define (longest-span spans)
    (let loop ([i 0] [longest 0])
      (if (fx= i (vector-length spans))
          longest
          (let ([s (vector-ref spans i)])
            (loop (fx+ i 1) (fxmax longest (fx- (span-entry-end s) (span-entry-start s))))))))

  (define (make-context v b doc)
    (let-values ([(lo hi) (bounds-of v)])
      (let-values ([(ws we) (window-range v doc lo hi)])
        (let ([spans (window-spans b v ws we)])
          (new-context v doc lo hi ws we (document:token doc 0)
                       (filter (lambda (m) (fx<= ws (car m) we)) (cursor-points v))
                       spans (longest-span spans) (fold-ranges v) '() (make-eqv-hashtable))))))

  ;; The drawn lines move only when the lines in view come within half
  ;; the margin of their edge, so a scroll by a line redraws no line and
  ;; the browser's morph keeps every line element.
  (define (window-lines v doc first last)
    (let* ([t (top-line v doc first last)]
           [n (view-record-count v)]
           [lv (fxmin last (fx+ t (fx- n 1)))]
           [margin (let ([m (* (drawn-margin) n)]) (if (>= m (fx- last first)) (fx- last first) (exact (ceiling m))))]
           [half (fxquotient margin 2)]
           [drawn (view-record-drawn v)])
      (if (and drawn
               (fx<= first (car drawn) t) (fx<= lv (cdr drawn) last)
               (or (fx= (car drawn) first) (fx>= (fx- t (car drawn)) half))
               (or (fx= (cdr drawn) last) (fx>= (fx- (cdr drawn) lv) half)))
          drawn
          (let ([drawn (cons (fxmax first (fx- t margin)) (fxmin last (fx+ lv margin)))])
            (view-record-drawn-set! v drawn)
            drawn))))

  (define (window-range v doc lo hi)
    (let-values ([(first last) (line-limits doc lo hi)])
      (let ([drawn (window-lines v doc first last)])
        (values (fxmax lo (document:line-start doc (car drawn)))
                (if (fx< (cdr drawn) last)
                    (fxmin hi (document:line-start doc (fx+ (cdr drawn) 1)))
                    hi)))))

  (define (spacer side lines height)
    (if (and height (fx> lines 0))
        (haml (:div.view-spacer ([data-spacer side] [data-lines lines]
                                 [style "height:" (exact (round (* lines height))) "px;overflow-anchor:none"])))
        '()))

  (define (view-html v doc ctx root-html)
    (let-values ([(first last) (line-limits doc (context-lo ctx) (context-hi ctx))])
      (let ([drawn (view-record-drawn v)] [height (view-record-line-height v)])
        (haml
          (:div.view ([data-view (view-record-id v)]
                      [data-placement (view-record-placement v)]
                      [data-place-line (document:line doc (spot-position (view-record-place-at v)))]
                      [data-place-align (symbol->string (view-record-place-align v))]
                      [data-place-offset (exact (round (view-record-place-offset v)))]
                      [style (if (wrap-lines) "overflow:auto;white-space:pre-wrap" "overflow:auto;white-space:pre")])
            (spacer "above" (fx- (car drawn) first) height)
            root-html
            (spacer "below" (fx- last (cdr drawn)) height))))))

  (define (empty-view-html v)
    (haml (:div.view ([data-view (view-record-id v)]))))

  (define failed (string->uninterned-symbol "failed"))

  (define (undefined-html ctx node inline?)
    (let ([content (if (document:atom? node) '() (children-html ctx node inline? #f))])
      (if inline?
          (haml (:span.undefined-kind content))
          (haml (:div.undefined-kind content)))))

  (define (draw-node ctx node inline?)
    (let* ([kind (buffers:kind (document:node-kind node))] [draw (and kind (buffers:kind-draw kind))])
      (cond
        [draw
         (let ([html (guard (c [(not (quit-condition? c))
                                (report-as (module-of-name (document:node-kind node)) c)
                                failed])
                       (if (eq? (in-line?) inline?)
                           (draw node (context-view ctx))
                           (parameterize ([in-line? inline?])
                             (draw node (context-view ctx)))))])
           (if (eq? html failed) (undefined-html ctx node inline?) html))]
        [kind (if (document:atom? node) '() (children-html ctx node inline? #f))]
        [else (undefined-html ctx node inline?)])))

  (define-record-type text-piece (sealed #t) (fields at string))
  (define-record-type fold-mark (sealed #t) (fields at))

  (define (items-of ctx node s e)
    (let ([folds (context-folds ctx)] [items '()])
      (define (fold-mark! f)
        (unless (memq f (context-shown ctx))
          (context-shown-set! ctx (cons f (context-shown ctx)))
          (set! items (cons (make-fold-mark (car f)) items))))
      (define (add-text! at str from)
        (let loop ([from from] [folds folds])
          (let ([a (fx+ at from)] [z (fx+ at (string-length str))])
            (cond
              [(fx= a z)]
              [(or (null? folds) (fx>= (caar folds) z))
               (set! items (cons (make-text-piece a (if (fx= from 0) str (substring str from (string-length str)))) items))]
              [(fx<= (cdar folds) a) (loop from (cdr folds))]
              [(fx< a (caar folds))
               (set! items (cons (make-text-piece a (substring str from (fx- (caar folds) at))) items))
               (loop (fx- (caar folds) at) folds)]
              [else
               (fold-mark! (car folds))
               (when (fx< (cdar folds) z)
                 (loop (fx- (cdar folds) at) (cdr folds)))]))))
      (document:for-each-child node s e
        (lambda (child at)
          (cond
            [(string? child) (add-text! at child 0)]
            [(null? folds) (set! items (cons child items))]
            [else
             (let* ([ns (document:node-start child)] [ne (document:node-end child)]
                    [f (find-first (lambda (f) (and (fx<= (car f) ns) (fx<= ne (cdr f)))) folds)])
               (if f (fold-mark! f) (set! items (cons child items))))])))
      (reverse items)))

  (define (children-html ctx node inline? wrap)
    (let* ([cs (fx+ (document:node-start node) 1)] [ce (fx- (document:node-end node) 1)]
           [s (fxmax cs (context-lo ctx) (if inline? 0 (context-ws ctx)))]
           [e (fxmin ce (context-hi ctx) (if inline? ce (context-we ctx)))])
      (cond
        [(fx> s e) '()]
        [inline? (line-content ctx (items-of ctx node s e) s e)]
        [else (block-html ctx node (items-of ctx node s e) s e ce wrap)])))

  (define (newline-index str from)
    (let loop ([i from])
      (cond
        [(fx= i (string-length str)) #f]
        [(char=? (string-ref str i) #\newline) i]
        [else (loop (fx+ i 1))])))

  ;; The empty run after a node's last newline is no line, or each block
  ;; would draw a blank line after its text; at the buffer's end, and
  ;; where a cursor rests, it is one, so that the cursor shows.
  (define (block-html ctx node items s e ce wrap)
    (let ([doc (context-doc ctx)] [root? (and (context-root ctx) (fx= (document:node-start node) 0))])
      (define (wrapped child html) (if wrap (wrap child html) html))
      (define (as-line run rs re line acc)
        (cons (wrapped rs (line-html ctx line (line-content ctx run rs re) (exists text-piece? run))) acc))
      (let loop ([items items] [run '()] [rs s] [known #f] [acc '()])
        (cond
          [(null? items)
           (let ([run (reverse run)])
             (reverse
               (cond
                 [(or (exists text-piece? run) (and (pair? run) (for-all fold-mark? run)))
                  (as-line run rs e (or known (document:line doc rs)) acc)]
                 [(pair? run) (append (reverse (block-items ctx run rs e wrapped)) acc)]
                 [(or (and root? (fx= e ce)) (pair? (cursors-in ctx rs e))) (as-line run rs e (or known (document:line doc rs)) acc)]
                 [else acc])))]
          [(text-piece? (car items))
           (let ([at (text-piece-at (car items))] [str (text-piece-string (car items))])
             (let split ([from 0] [run run] [rs rs] [known known] [acc acc])
               (let ([nl (newline-index str from)])
                 (if nl
                     (let ([run (reverse (if (fx= nl from) run (cons (make-text-piece (fx+ at from) (substring str from nl)) run)))]
                           [line (or known (document:line doc rs))])
                       (split (fx+ nl 1) '() (fx+ at nl 1) (and (for-all text-piece? run) (fx+ line 1))
                              (as-line run rs (fx+ at nl) line acc)))
                     (loop (cdr items)
                           (cond
                             [(fx= from 0) (cons (car items) run)]
                             [(fx= from (string-length str)) run]
                             [else (cons (make-text-piece (fx+ at from) (substring str from (string-length str))) run)])
                           rs known acc)))))]
          [else (loop (cdr items) (cons (car items) run) rs known acc)]))))

  ;; Lines carry the view's number and their own in their ids, so a
  ;; scroll's morph keeps the elements of the lines it moves.
  (define (line-html ctx line content text?)
    (let* ([ids (context-line-ids ctx)] [k (hashtable-ref ids line 0)])
      (hashtable-set! ids line (fx+ k 1))
      (haml (:div.line ([id "v" (view-record-id (context-view ctx)) "-" line (if (fx= k 0) "" (string-append "-" (number->string k)))]
                        [data-line line])
              content
              (unless text? (:br))))))

  (define (cursor-html primary?)
    (if primary? (haml (:span.cursor.primary)) (haml (:span.cursor))))

  (define fold-html (haml (:span.fold "…")))

  (define (block-items ctx run rs re wrapped)
    (let loop ([items run] [cursors (cursors-in ctx rs re)] [acc '()])
      (define (before p acc cursors)
        (if (and (pair? cursors) (fx<= (caar cursors) p))
            (before p (cons (cursor-html (cdar cursors)) acc) (cdr cursors))
            (values acc cursors)))
      (if (null? items)
          (let-values ([(acc cursors) (before re acc cursors)]) (reverse acc))
          (let ([item (car items)])
            (if (fold-mark? item)
                (let-values ([(acc cursors) (before (fold-mark-at item) acc cursors)])
                  (loop (cdr items) cursors (cons (wrapped (fold-mark-at item) fold-html) acc)))
                (let-values ([(acc cursors) (before (document:node-start item) acc cursors)])
                  (loop (cdr items)
                        (let skip ([cursors cursors])
                          (if (and (pair? cursors) (fx< (caar cursors) (document:node-end item))) (skip (cdr cursors)) cursors))
                        (cons (wrapped item (draw-node ctx item #f)) acc))))))))

  (define (cursors-in ctx lo hi)
    (filter (lambda (m) (fx<= lo (car m) hi)) (context-cursors ctx)))

  (define (spans-near ctx lo hi)
    (let* ([spans (context-spans ctx)] [n (vector-length spans)] [from (fx- lo (context-longest ctx))])
      (let search ([a 0] [z n])
        (if (fx< a z)
            (let ([m (fxquotient (fx+ a z) 2)])
              (if (fx< (span-entry-start (vector-ref spans m)) from) (search (fx+ m 1) z) (search a m)))
            (let collect ([i a] [acc '()])
              (if (or (fx= i n) (fx> (span-entry-start (vector-ref spans i)) hi))
                  (reverse acc)
                  (let ([s (vector-ref spans i)])
                    (collect (fx+ i 1) (if (fx>= (span-entry-end s) lo) (cons s acc) acc)))))))))

  (define (by-rank spans)
    (list-sort (lambda (a b)
                 (or (fx< (span-entry-rank a) (span-entry-rank b))
                     (and (fx= (span-entry-rank a) (span-entry-rank b)) (fx< (span-entry-start a) (span-entry-start b)))))
               spans))

  (define (datum-html ctx datum)
    (if (string? datum)
        datum
        (guard (c [(not (quit-condition? c)) (report c) '()])
          (let* ([doc (document:from-datum datum)] [n (document:length doc)]
                 [sub (new-context (context-view ctx) doc 0 n 0 n #f '() '#() 0 '() '() (context-line-ids ctx))])
            (parameterize ([current-context sub])
              (let loop ([p 0] [acc '()])
                (if (fx>= p n)
                    (reverse acc)
                    (let ([t (document:token doc p)])
                      (if (document:node? t)
                          (loop (document:node-end t) (cons (draw-node sub t #t) acc))
                          (loop (fx+ p 1) acc))))))))))

  ;; A cursor or span datum inside an inline node is the node's own to
  ;; draw, so the line passes over it.
  (define (line-content ctx items rs re)
    (let ([spans (spans-near ctx rs re)] [cursors (cursors-in ctx rs re)])
      (cond
        [(and (null? spans) (null? cursors))
         (map (lambda (item)
                (cond
                  [(document:node? item) (draw-node ctx item #t)]
                  [(text-piece? item) (text-piece-string item)]
                  [else fold-html]))
              items)]
        [(and (null? cursors) (for-all text-piece? items) (flat? spans)) (flat-content items spans)]
        [else
          (let ([insertions (list-sort
                               (lambda (a b) (or (fx< (insertion-at a) (insertion-at b))
                                                 (and (fx= (insertion-at a) (insertion-at b)) (fx< (insertion-order a) (insertion-order b)))))
                               (filter (lambda (i) (fx<= rs (insertion-at i) re))
                                       (append
                                         (fold-left
                                           (lambda (acc s)
                                             (define (datum d) (lambda () (datum-html ctx d)))
                                             (let* ([acc (if (span-entry-before s)
                                                             (cons (make-insertion (span-entry-start s) 0 (datum (span-entry-before s)) #f) acc)
                                                             acc)]
                                                    [acc (if (span-entry-replace s)
                                                             (cons (make-insertion (span-entry-start s) 1 (datum (span-entry-replace s)) s) acc)
                                                             acc)])
                                               (if (span-entry-after s)
                                                   (cons (make-insertion (span-entry-end s) 2 (datum (span-entry-after s)) #f) acc)
                                                   acc)))
                                           '() spans)
                                         (map (lambda (m) (make-insertion (car m) 3 (lambda () (cursor-html (cdr m))) #f)) cursors))))]
                [solid (filter (lambda (s) (fx< (span-entry-start s) (span-entry-end s))) spans)]
                [pieces '()])
            (define shown (by-rank (filter span-entry-open solid)))
            (define (add! stack html) (set! pieces (cons (cons stack html) pieces)))
            (define (covering p q)
              (filter (lambda (s) (and (fx<= (span-entry-start s) p) (fx>= (span-entry-end s) q))) shown))
            (define (inside p)
              (filter (lambda (s) (fx< (span-entry-start s) p (span-entry-end s))) shown))
            (define (replaced? p q)
              (exists (lambda (s) (and (span-entry-replace s) (fx<= (span-entry-start s) p) (fx>= (span-entry-end s) q))) solid))
            (define (emit-insertions! upto)
              (when (and (pair? insertions) (fx<= (insertion-at (car insertions)) upto))
                (let ([i (car insertions)])
                  (set! insertions (cdr insertions))
                  (add! (let ([s (insertion-span i)]) (if s (covering (span-entry-start s) (span-entry-end s)) (inside (insertion-at i))))
                        ((insertion-html i)))
                  (emit-insertions! upto))))
            (let ([cuts (list-sort fx< (append (map insertion-at insertions)
                                               (fold-left (lambda (acc s) (cons* (span-entry-start s) (span-entry-end s) acc))
                                                          '() solid)))])
              (for-each
                (lambda (item)
                  (cond
                    [(document:node? item)
                     (let ([ns (document:node-start item)] [ne (document:node-end item)])
                       (emit-insertions! ns)
                       (set! insertions (remp (lambda (i) (fx< ns (insertion-at i) ne)) insertions))
                       (add! (covering ns ne) (draw-node ctx item #t)))]
                    [(text-piece? item)
                     (let* ([at (text-piece-at item)] [str (text-piece-string item)] [z (fx+ at (string-length str))])
                       (let loop ([a at] [cuts (filter (lambda (c) (fx< at c z)) cuts)])
                         (let ([b (if (null? cuts) z (car cuts))])
                           (emit-insertions! a)
                           (unless (replaced? a b)
                             (add! (covering a b) (substring str (fx- a at) (fx- b at))))
                           (unless (null? cuts)
                             (loop b (let drop ([cs (cdr cuts)]) (if (and (pair? cs) (fx= (car cs) b)) (drop (cdr cs)) cs)))))))]
                    [else
                     (emit-insertions! (fold-mark-at item))
                     (add! '() fold-html)]))
                items))
            (emit-insertions! re)
            (nest (reverse pieces) 0))])))

  ;; Highlighting's spans seldom overlap: a line whose spans are apart,
  ;; with no cursor or datum in it, draws each span as one element.
  (define (flat? spans)
    (let loop ([spans spans] [end -1])
      (or (null? spans)
          (let ([s (car spans)])
            (cond
              [(or (span-entry-before s) (span-entry-after s) (span-entry-replace s)) #f]
              [(or (not (span-entry-open s)) (fx= (span-entry-start s) (span-entry-end s))) (loop (cdr spans) end)]
              [(fx< (span-entry-start s) end) #f]
              [else (loop (cdr spans) (span-entry-end s))])))))

  (define (flat-content items spans)
    (let ([spans (filter (lambda (s) (and (span-entry-open s) (fx< (span-entry-start s) (span-entry-end s)))) spans)])
      (let next ([items items] [spans spans] [acc '()])
        (if (null? items)
            (reverse acc)
            (let* ([at (text-piece-at (car items))] [str (text-piece-string (car items))] [z (fx+ at (string-length str))])
              (let loop ([a at] [spans spans] [acc acc])
                (cond
                  [(or (null? spans) (fx>= (span-entry-start (car spans)) z))
                   (next (cdr items) spans (if (fx< a z) (cons (substring str (fx- a at) (fx- z at)) acc) acc))]
                  [(fx<= (span-entry-end (car spans)) a) (loop a (cdr spans) acc)]
                  [else
                   (let* ([s (car spans)] [from (fxmax a (span-entry-start s))] [to (fxmin z (span-entry-end s))]
                          [acc (if (fx< a from) (cons (substring str (fx- a at) (fx- from at)) acc) acc)]
                          [acc (cons (list (span-entry-open s) (substring str (fx- from at) (fx- to at)) span-close) acc)])
                     (if (fx<= (span-entry-end s) z)
                         (loop to (cdr spans) acc)
                         (next (cdr items) spans acc)))])))))))

  (define span-close (raw-html "</span>"))
  (define region-open (raw-html "<span class=\"region\">"))

  (define (nest pieces depth)
    (let loop ([pieces pieces] [acc '()])
      (if (null? pieces)
          (reverse acc)
          (let ([stack (list-tail (caar pieces) depth)])
            (if (null? stack)
                (loop (cdr pieces) (cons (cdar pieces) acc))
                (let ([s (car stack)])
                  (let take ([rest pieces] [run '()])
                    (if (and (pair? rest)
                             (let ([t (list-tail (caar rest) depth)]) (and (pair? t) (eq? (car t) s))))
                        (take (cdr rest) (cons (car rest) run))
                        (loop rest (cons (list (span-entry-open s) (nest (reverse run) (fx+ depth 1)) span-close) acc))))))))))

  (define (showing who v)
    (or (bound-buffer v)
        (assertion-violation who "the view shows no buffer" v)))

  (define (move-point! v c p)
    (let ([b (view-record-buffer v)])
      (let-values ([(lo hi) (bounds-of v)])
        (set-cursor-spots! c (stop-within b lo hi p) (mark-of c))
        (cursor-record-goal-set! c #f))))

  (define (add-cursor-at! v p)
    (let ([b (view-record-buffer v)])
      (let-values ([(lo hi) (bounds-of v)])
        (let ([c (make-cursor-record v (make-spot b (stop-within b lo hi p) #f) #f #f)])
          (view-record-cursors-set! v (append (view-record-cursors v) (list c)))
          (mark-dirty!)
          c))))

  (define (add-fold! v start end)
    (let ([b (view-record-buffer v)])
      (view-record-folds-set! v (append (view-record-folds v) (list (cons (make-spot b start #t) (make-spot b end #f)))))
      (mark-dirty!)))

  ;; Narrowing keeps text inserted at either edge inside, as Emacs's
  ;; restriction does.
  (define (narrow-view! v start end)
    (let ([b (view-record-buffer v)])
      (view-record-narrowing-set! v (cons (make-spot b start #f) (make-spot b end #t)))
      (for-each
        (lambda (c)
          (let ([p (point-of c)])
            (unless (fx<= start p end) (move-point! v c p))))
        (view-record-cursors v))
      (let ([doc (buffers:document b)] [t (spot-position (view-record-top v))])
        (unless (fx<= (document:line doc start) (document:line doc t) (document:line doc end))
          (scroll-to-line! v doc (document:line doc start) 'top)))
      (primary-moved! v)
      (mark-dirty!)))

  (define (stop-after v b p)
    (let-values ([(lo hi) (bounds-of v)])
      (let loop ([q (buffers:next-stop b p)])
        (cond
          [(or (not q) (fx> q hi)) #f]
          [(fx< q lo) (loop (buffers:next-stop b q))]
          [(fold-holding v q)
           => (lambda (f)
                (let* ([e (spot-position (cdr f))] [s (buffers:stop b e)])
                  (loop (if (and s (fx>= s e)) s (buffers:next-stop b e)))))]
          [else q]))))

  (define (stop-before v b p)
    (let-values ([(lo hi) (bounds-of v)])
      (let loop ([q (buffers:previous-stop b p)])
        (cond
          [(or (not q) (fx< q lo)) #f]
          [(fx> q hi) (loop (buffers:previous-stop b q))]
          [(fold-holding v q)
           => (lambda (f)
                (let* ([e (spot-position (car f))] [s (buffers:stop b e)])
                  (loop (if (and s (fx<= s e)) s (buffers:previous-stop b e)))))]
          [else q]))))

  (define (with-view-bound v b thunk)
    (parameterize ([current-view v])
      (if b
          (buffers:call-with-buffer b (lambda () (call-with-view-options v thunk)))
          (call-with-view-options v thunk))))

  (define (draw-view v)
    (let ([b (bound-buffer v)])
      (if (not b)
          (empty-view-html v)
          (with-view-bound v b
            (lambda ()
              (open-folds-at-cursors! v)
              (let ([doc (buffers:document b)])
                (when (view-record-moved? v) (follow-cursor! v b doc))
                (let ([ctx (make-context v b doc)])
                  (parameterize ([current-context ctx] [in-line? #f] [drawing (cons v (drawing))])
                    (view-html v doc ctx (draw-node ctx (context-root ctx) #f))))))))))

  ;; View atoms: the first atom drawn in a batch that names a view draws
  ;; it; a later one names a copy, kept by its order among them, so each
  ;; draw of the same layout finds the same views. An atom is known by its
  ;; position and the buffer whose view draws it, or no buffer when drawn
  ;; through atom-view, since a node does not tell its document.
  (define claims (make-hashtable equal-hash equal?))
  (define copies (make-hashtable equal-hash equal?))

  (define (atom-view-of node host)
    (unless (and (document:atom? node) (eq? (document:node-kind node) 'views:view))
      (assertion-violation 'views:atom-view "not a view atom" node))
    (let* ([id (document:node-attribute node 'view)]
           [id (and (fixnum? id) (fx> id 0) id)]
           [name (let ([n (document:node-attribute node 'buffer "")]) (if (string? n) n ""))]
           [key (or id name)]
           [start (document:node-start node)]
           [claimed (hashtable-ref claims key '())]
           [k (let loop ([cs claimed] [k 0])
                (cond
                  [(null? cs) #f]
                  [(and (eq? (caar cs) host) (fx= (cdar cs) start)) k]
                  [else (loop (cdr cs) (fx+ k 1))]))]
           [k (or k (begin (hashtable-set! claims key (append claimed (list (cons host start)))) (length claimed)))])
      (define (new-view id) (make-new-view! id (buffers:find name) name))
      (let ([v (cond
                 [(fx> k 0)
                  (or (hashtable-ref copies (cons key k) #f)
                      (let ([v (new-view #f)] [original (and id (find-view id))])
                        (when original (copy-place! original v))
                        (hashtable-set! copies (cons key k) v)
                        v))]
                 [id (or (find-view id) (new-view id))]
                 [else
                  (or (hashtable-ref copies (cons key 0) #f)
                      (let ([v (new-view #f)]) (hashtable-set! copies (cons key 0) v) v))])])
        ;; Only a view an atom names by number is found again after a
        ;; restart; saving the others would add one to saved data at each.
        (when (and id (fx= k 0)) (view-record-saved?-set! v #t))
        (when host (view-record-host-set! v host))
        v)))

  (define (copy-place! from to)
    (let ([b (bound-buffer from)])
      (when (and b (eq? b (bound-buffer to)))
        (view-record-cursors-set! to
          (map (lambda (c) (make-cursor-record to (make-spot b (point-of c) #f)
                                               (let ([m (mark-of c)]) (and m (make-spot b m #f)))
                                               (cursor-record-goal c)))
               (view-record-cursors from)))
        (view-record-top-set! to (make-spot b (spot-position (view-record-top from)) #f))
        (view-record-place-at-set! to (make-spot b (spot-position (view-record-place-at from)) #f))
        (view-record-place-offset-set! to (view-record-place-offset from))
        (view-record-offset-set! to (view-record-offset from))
        (view-record-count-set! to (view-record-count from))
        (view-record-line-height-set! to (view-record-line-height from)))))

  (define (keymaps-at v b p)
    (let ([doc (buffers:document b)])
      (append
        (fold-left
          (lambda (acc l)
            (let ([keymap (buffers:layer-keymap l)])
              (if (and keymap
                       (or (pair? (buffers:spans-at l p))
                           (exists (lambda (s) (and (fx<= (car s) p) (fx< p (cadr s))))
                                   (buffers:spans l p (fxmin (fx+ p 1) (document:length doc))))))
                  (cons keymap acc)
                  acc)))
          '() (buffers:layers b v))
        (let loop ([n (document:enclosing doc p)] [acc '()])
          (if n
              (loop (document:enclosing doc (document:node-start n))
                    (let* ([kind (buffers:kind (document:node-kind n))] [keymap (and kind (buffers:kind-keymap kind))])
                      (if keymap (cons keymap acc) acc)))
              (reverse acc))))))

  (define own-options
    (list (cons 'drawn-margin drawn-margin) (cons 'scroll-margin scroll-margin)
          (cons 'scroll-conservatively scroll-conservatively) (cons 'wrap-lines wrap-lines)))

  (define (position? p) (and (fixnum? p) (fx>= p 0)))

  (define (range? r) (and (pair? r) (position? (car r)) (position? (cdr r))))

  (define (entry? e)
    (and (list? e) (fx= (length e) 8)
         (let-values ([(id name top placement cursors folds narrowing options) (apply values e)])
           (and (fixnum? id) (fx> id 0) (string? name) (position? top) (position? placement)
                (pair? cursors) (list? cursors)
                (for-all (lambda (c) (and (pair? c) (position? (car c)) (or (not (cdr c)) (position? (cdr c))))) cursors)
                (list? folds) (for-all range? folds)
                (or (not narrowing) (range? narrowing))
                (list? options) (for-all (lambda (o) (and (pair? o) (assq (car o) own-options))) options)))))

  (define (saved-state? x)
    (or (null? x) (and (pair? x) (fixnum? (car x)) (list? (cdr x)) (for-all entry? (cdr x)))))

  (define-saved state '() saved-state?)

  (define (entry-of v)
    (list (view-record-id v) (view-record-name v) (spot-position (view-record-top v)) (view-record-placement v)
          (map (lambda (c) (cons (point-of c) (mark-of c))) (view-record-cursors v))
          (map (lambda (f) (cons (spot-position (car f)) (spot-position (cdr f)))) (live-folds v))
          (let ([n (view-record-narrowing v)]) (and n (cons (spot-position (car n)) (spot-position (cdr n)))))
          (fold-right (lambda (e acc)
                        (let ([own (find-first (lambda (o) (eq? (cdr o) (view-option-option e))) own-options)])
                          (if (and own (plain-data? (view-option-value e)))
                              (cons (cons (car own) (view-option-value e)) acc)
                              acc)))
                      '() (view-record-options v))))

  (define (save!)
    (for-each bound-buffer views)
    (let ([now (cons next-id (map entry-of (filter view-record-saved? views)))])
      (unless (equal? now (state))
        (set-saved! state now))
      (set! dirty? #f)))

  (define (restore!)
    (let ([saved (state)])
      (unless (null? saved)
        (set! next-id (fxmax next-id (car saved)))
        (for-each
          (lambda (e)
            (let-values ([(id name top placement cursors folds narrowing options) (apply values e)])
              (unless (find-view id)
                (let ([v (make-view-record id name #f '() top 0 unmeasured-lines #f #f placement top 'top 0 #f
                                           folds narrowing '() '() #t #f #f)])
                  (view-record-cursors-set! v (map (lambda (c) (make-cursor-record v (car c) (cdr c) #f)) cursors))
                  (add-view! v)
                  (for-each
                    (lambda (o)
                      (guard (c [(not (quit-condition? c)) (report c)])
                        (set-view-option! 'views:set-option! v (cdr (assq (car o) own-options)) (cdr o) #f)))
                    options)))))
          (cdr saved))
        (set! dirty? #f))))

  ;; An edit that deletes the node holding a cursor leaves its anchor
  ;; where no cursor may rest. Whether a position is a stop depends on the
  ;; nodes around it, so the cursors move once a batch, after its edits.
  (define edited '())

  (define (cursors-to-stops! v b)
    (let-values ([(lo hi) (bounds-of v)])
      (for-each
        (lambda (c)
          (let ([p (point-of c)])
            (unless (eqv? (buffers:stop b p) p)
              (cursor-record-point-set! c (move-spot (cursor-record-point c) b (stop-within b lo hi p) #f)))))
        (view-record-cursors v))))

  (define (note-edit buffer edit)
    (let ([vs (hashtable-ref by-buffer buffer '())])
      (unless (null? vs)
        (set! dirty? #t)
        (unless (memq buffer edited) (set! edited (cons buffer edited)))
        (for-each
          (lambda (v)
            (unless (null? (cdr (view-record-cursors v)))
              (merge-cursors! v)))
          vs))))

  (define (note-kill buffer)
    (for-each (lambda (v) (when (eq? (view-record-host v) buffer) (drop-view! v))) views)
    (for-each
      (lambda (v)
        (let ([next (let loop ([bs (buffers:all)] [newest #f])
                      (cond [(null? bs) newest]
                            [(eq? (car bs) buffer) (loop (cdr bs) newest)]
                            [else (loop (cdr bs) (car bs))]))])
          (if next
              (show-buffer! v next)
              (begin (reset-view! v #f) (set-shown-buffer! v #f)))))
      (hashtable-ref by-buffer buffer '())))

  (define (after-batch ended)
    (ended)
    (hashtable-clear! claims)
    (let ([bs edited])
      (set! edited '())
      (for-each
        (lambda (b)
          (when (buffers:live? b)
            (for-each
              (lambda (v)
                (cursors-to-stops! v b)
                (unless (null? (cdr (view-record-cursors v)))
                  (merge-cursors! v)))
              (hashtable-ref by-buffer b '()))))
        bs))
    (for-each
      (lambda (v)
        (let ([b (view-record-buffer v)])
          (when b
            (open-folds-at-cursors! v)
            (unless (string=? (view-record-name v) (buffers:name b))
              (view-record-name-set! v (buffers:name b))
              (mark-dirty!)))))
      views)
    (when dirty? (save!)))

  (define (scroll-report client item)
    (define (field key) (let ([e (assoc key item)]) (and e (cdr e))))
    (let ([id (field "view")] [placement (field "placement")] [top (field "top")]
          [offset (field "offset")] [last (field "last")] [height (field "height")])
      (unless (and (fixnum? id) (fixnum? placement) (fixnum? top) (fixnum? last) (real? offset) (finite? offset) (real? height) (finite? height))
        (assertion-violation 'views "not a scroll report" item))
      (let ([v (find-view id)])
        (and v (fx>= placement (view-record-placement v))
             (let ([b (bound-buffer v)])
               (and b
                    (let* ([doc (buffers:document b)] [lines (document:line doc (document:length doc))])
                      (when (> height 0) (view-record-line-height-set! v (inexact height)))
                      (list v (document:line-start doc (fxmax 1 (fxmin lines top))) offset
                            (document:line-start doc (fxmax 1 (fxmin lines last)))))))))))

  (define (face-attributes face)
    (let ([class (cond
                   [(symbol? face) (symbol->string face)]
                   [(string? face) face]
                   [(and (list? face) (for-all symbol? face))
                    (let loop ([fs face] [acc ""])
                      (if (null? fs) acc (loop (cdr fs) (if (string=? acc "") (symbol->string (car fs))
                                                            (string-append acc " " (symbol->string (car fs)))))))]
                   [else #f])])
      (if class (list (cons "class" class)) '())))

  (define (title-attributes title)
    (if (string? title) (list (cons "title" title)) '()))

  (record-writer (record-type-descriptor view-record)
    (lambda (v p wr) (fprintf p "#<view ~a>" (view-record-id v))))

  (record-writer (record-type-descriptor cursor-record)
    (lambda (c p wr) (fprintf p "#<cursor>")))

  (restore!))

(import %internals)

(define (make buffer)
  (check-main-thread 'views:make)
  (check-live-buffer 'views:make buffer)
  (make-new-view! #f buffer (buffers:name buffer)))

(define (buffer view)
  (check-view 'views:buffer view)
  (bound-buffer view))

(define (set-buffer! view buffer)
  (check-view 'views:set-buffer! view)
  (check-live-buffer 'views:set-buffer! buffer)
  (show-buffer! view buffer))

(define (drop! view)
  (check-view 'views:drop! view)
  (drop-view! view))

(define (id view)
  (unless (view-record? view)
    (assertion-violation 'views:id "not a view" view))
  (when (view-record-dropped? view)
    (assertion-violation 'views:id "a dropped view" view))
  (view-record-id view))

(define (find id)
  (unless (and (fixnum? id) (fx> id 0))
    (assertion-violation 'views:find "not a view number" id))
  (find-view id))

(define (view? v) (view-record? v))

(define-syntax with-view
  (syntax-rules ()
    [(_ view-expr body1 body2 ...) (call-with-view view-expr (lambda () body1 body2 ...))]))

(define (call-with-view view thunk)
  (check-view 'views:call-with-view view)
  (unless (procedure? thunk)
    (assertion-violation 'views:call-with-view "not a procedure" thunk))
  (with-view-bound view (bound-buffer view) thunk))

(define (current) (current-view))

(define (point view)
  (check-view 'views:point view)
  (bound-buffer view)
  (point-of (car (view-record-cursors view))))

(define (set-point! view position)
  (check-view 'views:set-point! view)
  (showing 'views:set-point! view)
  (check-position 'views:set-point! view position)
  (move-point! view (car (view-record-cursors view)) position)
  (primary-moved! view))

(define (mark view)
  (check-view 'views:mark view)
  (bound-buffer view)
  (mark-of (car (view-record-cursors view))))

(define (set-mark! view position)
  (check-view 'views:set-mark! view)
  (showing 'views:set-mark! view)
  (when position (check-position 'views:set-mark! view position))
  (let ([c (car (view-record-cursors view))])
    (set-cursor-spots! c (point-of c) position)))

(define (cursors view)
  (check-view 'views:cursors view)
  (bound-buffer view)
  (view-record-cursors view))

(define (add-cursor! view position)
  (check-view 'views:add-cursor! view)
  (showing 'views:add-cursor! view)
  (check-position 'views:add-cursor! view position)
  (add-cursor-at! view position))

(define (remove-cursor! view cursor)
  (check-view 'views:remove-cursor! view)
  (check-cursor 'views:remove-cursor! cursor)
  (let ([cs (view-record-cursors view)])
    (unless (memq cursor cs)
      (assertion-violation 'views:remove-cursor! "not a cursor of the view" cursor))
    (when (null? (cdr cs))
      (assertion-violation 'views:remove-cursor! "the view's last cursor" cursor))
    (when (eq? cursor (car cs)) (primary-moved! view))
    (view-record-cursors-set! view (remq cursor cs))
    (mark-dirty!)))

(define (cursor-point cursor)
  (check-cursor 'views:cursor-point cursor)
  (bound-buffer (cursor-record-view cursor))
  (point-of cursor))

(define (cursor-mark cursor)
  (check-cursor 'views:cursor-mark cursor)
  (bound-buffer (cursor-record-view cursor))
  (mark-of cursor))

(define (set-cursor! cursor point mark)
  (check-cursor 'views:set-cursor! cursor)
  (let ([view (cursor-record-view cursor)])
    (unless (memq cursor (view-record-cursors view))
      (assertion-violation 'views:set-cursor! "not a cursor of the view" cursor))
    (showing 'views:set-cursor! view)
    (check-position 'views:set-cursor! view point)
    (when mark (check-position 'views:set-cursor! view mark))
    (move-point! view cursor point)
    (set-cursor-spots! cursor (point-of cursor) mark)
    (when (eq? cursor (car (view-record-cursors view))) (primary-moved! view))))

(define (cursor-goal cursor)
  (check-cursor 'views:cursor-goal cursor)
  (cursor-record-goal cursor))

(define (set-cursor-goal! cursor column)
  (check-cursor 'views:set-cursor-goal! cursor)
  (unless (or (not column) (and (fixnum? column) (fx>= column 0)))
    (assertion-violation 'views:set-cursor-goal! "not a column or #f" column))
  (cursor-record-goal-set! cursor column))

(define (cursor? v) (cursor-record? v))

(define (next-stop view position)
  (check-view 'views:next-stop view)
  (let ([b (showing 'views:next-stop view)])
    (check-position 'views:next-stop view position)
    (stop-after view b position)))

(define (previous-stop view position)
  (check-view 'views:previous-stop view)
  (let ([b (showing 'views:previous-stop view)])
    (check-position 'views:previous-stop view position)
    (stop-before view b position)))

(define (top view)
  (check-view 'views:top view)
  (bound-buffer view)
  (spot-position (view-record-top view)))

(define (scroll-to! view position alignment)
  (check-view 'views:scroll-to! view)
  (let ([b (showing 'views:scroll-to! view)])
    (check-position 'views:scroll-to! view position)
    (unless (memq alignment '(top center bottom))
      (assertion-violation 'views:scroll-to! "not an alignment" alignment))
    (let ([doc (buffers:document b)])
      (scroll-to-line! view doc (document:line doc position) alignment))))

(define (scrolled! view top offset last)
  (check-view 'views:scrolled! view)
  (let ([n (let ([b (bound-buffer view)]) (if b (document:length (buffers:document b)) (most-positive-fixnum)))])
    (unless (and (fixnum? top) (fx<= 0 top n) (fixnum? last) (fx<= 0 last n))
      (assertion-violation 'views:scrolled! "not positions in the view's buffer" top last))
    (unless (and (real? offset) (finite? offset))
      (assertion-violation 'views:scrolled! "not a finite real number" offset))
    (scrolled view top offset last)))

(define (fold! view start end)
  (check-view 'views:fold! view)
  (showing 'views:fold! view)
  (check-position 'views:fold! view start)
  (check-position 'views:fold! view end)
  (unless (fx<= start end)
    (assertion-violation 'views:fold! "the start is after the end" start end))
  (add-fold! view start end))

(define (unfold! view position)
  (check-view 'views:unfold! view)
  (showing 'views:unfold! view)
  (check-position 'views:unfold! view position)
  (view-record-folds-set! view
    (remp (lambda (f) (fx<= (spot-position (car f)) position (spot-position (cdr f)))) (live-folds view)))
  (mark-dirty!))

(define (folded? view position)
  (check-view 'views:folded? view)
  (showing 'views:folded? view)
  (check-position 'views:folded? view position)
  (exists (lambda (f) (fx<= (spot-position (car f)) position (spot-position (cdr f)))) (live-folds view)))

(define (narrow! view start end)
  (check-view 'views:narrow! view)
  (showing 'views:narrow! view)
  (check-position 'views:narrow! view start)
  (check-position 'views:narrow! view end)
  (unless (fx<= start end)
    (assertion-violation 'views:narrow! "the start is after the end" start end))
  (narrow-view! view start end))

(define (widen! view)
  (check-view 'views:widen! view)
  (view-record-narrowing-set! view #f)
  (mark-dirty!))

(define (bounds view)
  (check-view 'views:bounds view)
  (bound-buffer view)
  (bounds-of view))

(define (set-option! view option v)
  (check-view 'views:set-option! view)
  (check-option 'views:set-option! option)
  (set-view-option! 'views:set-option! view option v (current-owner)))

(define (remove-option! view option)
  (check-view 'views:remove-option! view)
  (check-option 'views:remove-option! option)
  (remove-view-option! view option))

(define (node-state view node default)
  (check-view 'views:node-state view)
  (check-node 'views:node-state node)
  (let-values ([(b at entry) (state-entry view node)])
    (if entry (cdr entry) default)))

(define (set-node-state! view node v)
  (check-view 'views:set-node-state! view)
  (check-node 'views:set-node-state! node)
  (let-values ([(b at entry) (state-entry view node)])
    (if entry
        (set-cdr! entry v)
        (view-record-states-set! view (cons (cons (buffers:anchor b at) v) (view-record-states view))))))

(define (%draw-view-atom node view)
  (let ([inner (atom-view-of node (bound-buffer view))])
    (if (drawing? inner) '() (draw inner))))

(buffers:define-kind view (content atom) (draw %draw-view-atom))

(define (atom-view node)
  (check-main-thread 'views:atom-view)
  (check-node 'views:atom-view node)
  (atom-view-of node #f))

(define (draw view)
  (check-view 'views:draw view)
  (draw-view view))

(define draw-children
  (case-lambda
    [(view node) (draw-children view node #f)]
    [(view node wrap)
     (check-view 'views:draw-children view)
     (check-node 'views:draw-children node)
     (unless (or (not wrap) (procedure? wrap))
       (assertion-violation 'views:draw-children "not a procedure" wrap))
     (let ([ctx (current-context)])
       (if (and ctx (eq? (context-view ctx) view))
           (children-html ctx node (in-line?) wrap)
           (let ([b (bound-buffer view)])
             (if b
                 (children-html (make-context view b (buffers:document b)) node #f wrap)
                 '()))))]))

(define (keymaps view)
  (check-view 'views:keymaps view)
  (let ([b (bound-buffer view)])
    (if b (keymaps-at view b (point-of (car (view-record-cursors view)))) '())))

(define (%scroll-report client item)
  (let ([report (scroll-report client item)])
    (when report (apply scrolled! report))))

(table-set! span-properties 'face face-attributes)
(table-set! span-properties 'title title-attributes)
(table-set! web:scripts 'views "views/views.js")
(table-set! web:input-handlers "scroll" %scroll-report)
(add-hook! buffers:after-edit note-edit)
(add-hook! buffers:killed note-kill)
(advice-add! batch-ended after-batch)
