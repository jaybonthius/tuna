#!tuna
(import (document) (buffers) (views) (commands) (keys) (kill-ring) (undo) (layout) (web))

(define-option delete-selection #f boolean?
  "When true, typing, newline, paste and yank replace an active, non-empty region, and delete-char and delete-backward-char delete it.")

(define-option word-characters "$%" string?
  "The characters besides letters and digits that are part of words.")

(module %internals
  (check-main-thread check-count check-nonnegative-count command-view content-bounds for-each-cursor
   place-kept! move-kept! edge-error stops-from move-cursors! end-of-line first-stop clear-marks!
   set-marks! forget-temporary! exchange-marks! check-regions word-characters-in words-from
   line-motion-target recase! capitalizer replace-region-or! insert-at-cursors! kill-ranges! after-kill?
   remember-kill! yank-pieces! yanked-in? replace-yank! pure-text note-change! clear-changed-marks!
   nonempty-region? shift-selected keep-changed-marks! place! select-between! drag-keymap start-drag! drag-in drag-anchor-position drag-mode
   drag-moved? drag-moved?-set!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-count who n)
    (unless (and (integer? n) (exact? n))
      (assertion-violation who "not an exact integer" n)))

  (define (check-nonnegative-count who n)
    (unless (and (integer? n) (exact? n) (>= n 0))
      (assertion-violation who "not a non-negative count" n)))

  (define (command-view who)
    (let ([v (views:current)])
      (unless v
        (assertion-violation who "no view is current"))
      (unless (views:buffer v)
        (assertion-violation who "the view shows no buffer" v))
      v))

  ;; A buffer's root is one node, so its content runs from after the
  ;; root's opening to before its closing.
  (define (content-bounds view doc)
    (let-values ([(lo hi) (views:bounds view)])
      (values (fxmax lo 1) (fxmin hi (fx- (document:length doc) 1)))))

  ;; Views merge cursors that meet after each edit, so one cursor's edit
  ;; can remove another before its turn, or the cursor itself. Every
  ;; cursor's point and mark are anchored before the first edit, so each
  ;; acts where it was, and only a cursor still in the view is placed.
  ;; The lower of point and mark moves after text inserted there and the
  ;; higher stays before it, so text another cursor inserts at an edge
  ;; stays outside the region.
  (define (for-each-cursor view proc)
    (let ([b (views:buffer view)])
      (define (anchor p other)
        (if (and other (fx> p other)) (buffers:anchor b p) (buffers:anchor-after b p)))
      (for-each
        (lambda (s)
          (let ([m (cddr s)])
            (proc (car s) (buffers:anchor-position (cadr s)) (and m (buffers:anchor-position m)))))
        (map (lambda (c)
               (let ([p (views:cursor-point c)] [m (views:cursor-mark c)])
                 (cons* c (anchor p m) (and m (anchor m p)))))
             (views:cursors view)))))

  (define (place-kept! view c point mark)
    (when (memq c (views:cursors view))
      (views:set-cursor! c point mark)))

  (define (move-kept! view c point)
    (when (memq c (views:cursors view))
      (views:set-cursor! c point (views:cursor-mark c))))

  ;; The mark shift selection set, by cursor, so the next unshifted motion
  ;; clears it but leaves a mark that set-mark-command or other code set.
  (define temporary (make-weak-eq-hashtable))

  (define (forget-temporary! c) (eq-hashtable-delete! temporary c))

  (define (temporary-mark? c m)
    (and m (eqv? (eq-hashtable-ref temporary c #f) m)))

  (define (place! c p shift?)
    (let ([m (views:cursor-mark c)])
      (cond
        [(and shift? m) (views:set-cursor! c p m)]
        [shift?
         (let ([q (views:cursor-point c)])
           (eq-hashtable-set! temporary c q)
           (views:set-cursor! c p q))]
        [(temporary-mark? c m)
         (forget-temporary! c)
         (views:set-cursor! c p #f)]
        [else (views:set-cursor! c p m)])))

  ;; As in Emacs, a swapped shift-selected region is still cleared by the
  ;; next unshifted motion.
  (define (exchange-marks! view)
    (for-each
      (lambda (c)
        (let ([p (views:cursor-point c)] [m (views:cursor-mark c)])
          (when m
            (when (temporary-mark? c m) (eq-hashtable-set! temporary c p))
            (views:set-cursor! c m p))))
      (views:cursors view)))

  ;; Setting the primary cursor would also scroll its view to point,
  ;; which a view that only loses its mark, such as another view of an
  ;; edited buffer, must not do.
  (define (set-mark-of! view c mark)
    (forget-temporary! c)
    (if (eq? c (car (views:cursors view)))
        (views:set-mark! view mark)
        (views:set-cursor! c (views:cursor-point c) mark)))

  (define (clear-marks! view)
    (for-each
      (lambda (c) (if (views:cursor-mark c) (set-mark-of! view c #f) (forget-temporary! c)))
      (views:cursors view)))

  (define (set-marks! view mark-of)
    (for-each (lambda (c) (set-mark-of! view c (mark-of c))) (views:cursors view)))

  ;; Views merge cursors that meet only after an edit, so a motion merges
  ;; those it brought together itself.
  (define (merge-met! view)
    (let loop ([cs (views:cursors view)] [seen '()])
      (unless (null? cs)
        (let ([p (views:cursor-point (car cs))])
          (if (memv p seen)
              (begin (views:remove-cursor! view (car cs)) (loop (cdr cs) seen))
              (loop (cdr cs) (cons p seen)))))))

  (define (edge-error who n)
    (error who (if (> n 0) "end of buffer" "beginning of buffer")))

  (define (stops-from view p n)
    (let loop ([p p] [k (abs n)])
      (let ([next (and (> k 0) (if (> n 0) (views:next-stop view p) (views:previous-stop view p)))])
        (if next (loop next (- k 1)) p))))

  (define (move-cursors! who view n target)
    (let* ([doc (buffers:document (views:buffer view))]
           [shift? (keys:shift-translated?)]
           [primary (car (views:cursors view))]
           [before (views:cursor-point primary)])
      (let-values ([(lo hi) (content-bounds view doc)])
        (for-each
          (lambda (c)
            (let-values ([(p goal) (target c doc lo hi)])
              (place! c (fxmax lo (fxmin hi p)) shift?)
              (when goal (views:set-cursor-goal! c goal))))
          (views:cursors view)))
      (merge-met! view)
      (when (and (not (= n 0)) (memq primary (views:cursors view)) (fx= (views:cursor-point primary) before))
        (edge-error who n))))

  (define chars (document:unit characters))

  (define (end-of-line doc line hi)
    (if (fx< line (document:line doc hi))
        (fxmin hi (fx- (document:line-start doc (fx+ line 1)) 1))
        hi))

  ;; The start of a line is often before openings, as of a paragraph that
  ;; holds the line; the cursor rests at the first stop after them.
  (define (first-stop b p) (or (buffers:stop b p) p))

  (define (column doc p)
    (fx- (document:offset doc p chars)
         (document:offset doc (document:line-start doc (document:line doc p)) chars)))

  (define (line-motion-target n line-motion?)
    (lambda (c doc lo hi)
      (let* ([p (views:cursor-point c)]
             [goal (or (and line-motion? (views:cursor-goal c)) (column doc p))]
             [target (+ (document:line doc p) n)])
        (cond
          [(< target (document:line doc lo)) (values lo goal)]
          [(> target (document:line doc hi)) (values hi goal)]
          [else
           (let* ([start (document:line-start doc target)]
                  [end (end-of-line doc target hi)]
                  [offset (fxmin (fx+ (document:offset doc start chars) goal)
                                 (document:offset doc end chars))])
             (values (fxmax lo (document:position doc offset chars)) goal))]))))

  (define (check-regions who view)
    (for-each
      (lambda (c)
        (unless (views:cursor-mark c)
          (error who "the mark is not set, so there is no region")))
      (views:cursors view)))

  ;; Read in the buffer's scope, so a mode's local value applies.
  (define (word-characters-in buffer)
    (if (eq? buffer (buffers:current))
        (word-characters)
        (buffers:call-with-buffer buffer word-characters)))

  (define (holds-char? s ch)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (and (fx< i n) (or (char=? (string-ref s i) ch) (loop (fx+ i 1)))))))

  (define (word-char? t extra)
    (and (char? t)
         (or (char-alphabetic? t)
             (char-numeric? t)
             (holds-char? extra t))))

  (define (word-end doc p hi extra)
    (let skip ([p p])
      (cond
        [(fx>= p hi) #f]
        [(word-char? (document:token doc p) extra)
         (let in ([p (fx+ p 1)])
           (if (and (fx< p hi) (word-char? (document:token doc p) extra)) (in (fx+ p 1)) p))]
        [else (skip (fx+ p 1))])))

  (define (word-start doc p lo extra)
    (let skip ([p p])
      (cond
        [(fx<= p lo) #f]
        [(word-char? (document:token doc (fx- p 1)) extra)
         (let in ([p (fx- p 1)])
           (if (and (fx> p lo) (word-char? (document:token doc (fx- p 1)) extra)) (in (fx- p 1)) p))]
        [else (skip (fx- p 1))])))

  (define (words-from doc p n lo hi extra)
    (let loop ([p (fxmax lo (fxmin hi p))] [n n])
      (cond
        [(= n 0) p]
        [(> n 0) (let ([e (word-end doc p hi extra)]) (if e (loop e (- n 1)) hi))]
        [else (let ([s (word-start doc p lo extra)]) (if s (loop s (+ n 1)) lo))])))

  (define replacement-char (integer->char #xFFFC))

  ;; Openings, closings and atoms between characters are kept, so only
  ;; the runs of characters between them change.
  (define (char-runs doc start end)
    (let ([text (document:text doc start end)])
      (if (and (fx= (string-length text) (fx- end start))
               (not (holds-char? text replacement-char)))
          (list (cons start text))
          (let loop ([p start] [run #f] [acc '()])
            (define (close) (if run (cons (cons run (document:text doc run p)) acc) acc))
            (cond
              [(fx= p end) (reverse (close))]
              [(char? (document:token doc p)) (loop (fx+ p 1) (or run p) acc)]
              [else (loop (fx+ p 1) #f (close))])))))

  (define (pure-text doc start end)
    (let ([runs (char-runs doc start end)])
      (and (or (null? runs) (and (null? (cdr runs)) (fx= (caar runs) start)
                                 (fx= (string-length (cdar runs)) (fx- end start))))
           (if (null? runs) "" (cdar runs)))))

  ;; A case mapping such as ß to SS changes a text's length, so callers
  ;; need the change in length to place the cursor.
  (define (recase! b start end convert)
    (fold-left
      (lambda (delta run)
        (let* ([old (cdr run)] [new (convert old)])
          (if (string=? old new)
              delta
              (begin
                (buffers:replace! b (car run) (fx+ (car run) (string-length old)) new)
                (fx+ delta (fx- (string-length new) (string-length old)))))))
      0
      (reverse (char-runs (buffers:document b) start end))))

  ;; Each run starts a word, since an opening, closing or atom ends one.
  (define (capitalizer extra)
    (lambda (s)
      (let ([n (string-length s)])
        (let-values ([(out done) (open-string-output-port)])
          (let loop ([i 0])
            (when (fx< i n)
              (if (word-char? (string-ref s i) extra)
                  (let word ([j (fx+ i 1)])
                    (if (and (fx< j n) (word-char? (string-ref s j) extra))
                        (word (fx+ j 1))
                        (begin
                          (put-string out (string-titlecase (string (string-ref s i))))
                          (put-string out (string-downcase (substring s (fx+ i 1) j)))
                          (loop j))))
                  (begin (put-char out (string-ref s i)) (loop (fx+ i 1))))))
          (done)))))

  (define (nonempty-region? p m) (and m (not (fx= m p))))

  (define (selected-region p m delete-selection?)
    (and delete-selection? (nonempty-region? p m) (cons (fxmin p m) (fxmax p m))))

  (define (insert-at-cursors! view content delete-selection? after-insert)
    (let ([b (views:buffer view)])
      (for-each-cursor view
        (lambda (c p m)
          (let* ([r (selected-region p m delete-selection?)]
                 [edit (if r
                           (buffers:replace! b (car r) (cdr r) content)
                           (buffers:replace! b p p content))]
                 [start (buffers:edit-start edit)])
            (forget-temporary! c)
            (place-kept! view c
              (after-insert start (fx+ start (document:length (buffers:edit-inserted edit))))
              #f))))))

  (define (replace-region-or! view delete-selection? otherwise)
    (let ([b (views:buffer view)])
      (for-each-cursor view
        (lambda (c p m)
          (let ([r (selected-region p m delete-selection?)])
            (if r
                (begin
                  (buffers:replace! b (car r) (cdr r) "")
                  (forget-temporary! c)
                  (place-kept! view c (car r) #f))
                (otherwise c p)))))))

  (define (add-kill! entry backward? after-kill?)
    (cond
      [(not after-kill?) (kill-ring:push! entry)]
      [backward? (kill-ring:prepend! entry)]
      [else (kill-ring:append! entry)]))

  (define-record-type cursor-range
    (sealed #t)
    (fields cursor start end))

  ;; The start moves after text inserted there and the end stays before
  ;; it, so text another cursor inserts at an edge stays outside. An
  ;; empty range then turns inside out, so its ends are read in order.
  (define (anchor-range b c start end)
    (make-cursor-range c (buffers:anchor-after b start) (buffers:anchor b end)))

  (define (range-bounds r)
    (let ([s (buffers:anchor-position (cursor-range-start r))]
          [e (buffers:anchor-position (cursor-range-end r))])
      (values (fxmin s e) (fxmax s e))))

  ;; Ranges that overlap, as of two cursors on one line killing to its
  ;; end, would put the same text on the ring twice, so each starts where
  ;; the ranges before it end; a range inside another becomes empty.
  (define (clip-ranges ranges)
    (let loop ([rs (list-sort (lambda (x y) (fx< (car x) (car y))) ranges)] [reached 0])
      (unless (null? rs)
        (let ([r (car rs)])
          (when (fx< (car r) reached)
            (set-car! r reached)
            (set-cdr! r (fxmax (cdr r) reached)))
          (loop (cdr rs) (fxmax reached (cdr r))))))
    ranges)

  ;; Any command that kills through kill-ranges! is a kill command, as
  ;; any that kills through kill-region is in Emacs. It is recorded when
  ;; the command ends, so the next kill joins only a command that killed.
  (define killing? #f)
  (define kill-command #f)

  ;; Only a run of the kill's own command that kills nothing forgets the
  ;; kill: any other command either becomes the last command, which the
  ;; next kill then does not join, or is a prefix command, which leaves
  ;; the kill as the last command.
  (define (remember-kill! command)
    (cond
      [killing? (set! kill-command command)]
      [(eq? command kill-command) (set! kill-command #f)])
    (set! killing? #f))

  (define (after-kill?)
    (let ([last (commands:last-command)])
      (and last (eq? last kill-command))))

  ;; Every range is read and put on the ring before any is deleted, so a
  ;; deletion the buffer refuses keeps the text on the ring.
  (define (kill-ranges! view ends-of delete?)
    (let* ([b (views:buffer view)]
           [cursors (views:cursors view)]
           [ends (map (lambda (c) (call-with-values (lambda () (ends-of c)) cons)) cursors)]
           [ranges (clip-ranges (map (lambda (e) (cons (fxmin (car e) (cdr e)) (fxmax (car e) (cdr e)))) ends))])
      (add-kill!
        (map (lambda (r) (kill-ring:piece b (car r) (cdr r))) ranges)
        (fx< (cdar ends) (caar ends))
        (after-kill?))
      (when delete?
        (when (commands:this-command) (set! killing? #t))
        (for-each
          (lambda (r)
            (let-values ([(start end) (range-bounds r)])
              (buffers:replace! b start end "")
              (forget-temporary! (cursor-range-cursor r))
              (place-kept! view (cursor-range-cursor r) start #f)))
          (map (lambda (c r) (anchor-range b c (car r) (cdr r))) cursors ranges)))))

  (define last-yank '())
  (define yank-view #f)

  (define (piece-for entry count)
    (if (fx= (length entry) count)
        (lambda (i) (list-ref entry i))
        (let ([text (kill-ring:text entry)]) (lambda (i) text))))

  ;; The record is set only once every piece is in, so a quit part-way
  ;; makes the next yank-pop raise rather than act on half a record.
  (define (yank-pieces! view entry delete-selection?)
    (let ([b (views:buffer view)] [piece (piece-for entry (length (views:cursors view)))] [yanked '()])
      (set! last-yank '())
      (set! yank-view view)
      (for-each-cursor view
        (lambda (c p m)
          (let* ([r (selected-region p m delete-selection?)]
                 [start (if r (begin (buffers:replace! b (car r) (cdr r) "") (car r)) p)]
                 [end (kill-ring:insert! b start (piece (length yanked)))])
            (set! yanked (cons (anchor-range b c start end) yanked))
            (forget-temporary! c)
            (place-kept! view c end start))))
      (set! last-yank (reverse yanked))))

  (define (yanked-in? view) (and (eq? yank-view view) (pair? last-yank)))

  (define (replace-yank! view entry)
    (let ([b (views:buffer view)] [ys last-yank] [piece (piece-for entry (length last-yank))])
      (set! last-yank '())
      (let loop ([rs ys] [i 0])
        (unless (null? rs)
          (let ([r (car rs)])
            (let-values ([(start old-end) (range-bounds r)])
              (buffers:replace! b start old-end "")
              (let ([end (kill-ring:insert! b start (piece i))])
                ;; The start moved after the text inserted at it.
                (buffers:set-anchor! (cursor-range-start r) start)
                (buffers:set-anchor! (cursor-range-end r) end)
                (place-kept! view (cursor-range-cursor r) end start)))
            (loop (cdr rs) (fx+ i 1)))))
      (set! last-yank ys)))

  (define (same-run? first t extra)
    (and (char? t)
         (cond
           [(word-char? first extra) (word-char? t extra)]
           [(char-whitespace? first) (char-whitespace? t)]
           [else (char=? t first)])))

  (define (run-bounds doc p lo hi extra)
    (let ([first (and (fx< p hi) (document:token doc p))])
      (if (char? first)
          (values (let loop ([q p])
                    (if (and (fx> q lo) (same-run? first (document:token doc (fx- q 1)) extra)) (loop (fx- q 1)) q))
                  (let loop ([q (fx+ p 1)])
                    (if (and (fx< q hi) (same-run? first (document:token doc q) extra)) (loop (fx+ q 1)) q)))
          (values p p))))

  (define (mouse-range doc a b mode lo hi extra)
    (let ([s (fxmin a b)] [e (fxmax a b)])
      (case mode
        [(2) (values (let-values ([(from to) (run-bounds doc s lo hi extra)]) from)
                     (let-values ([(from to) (run-bounds doc e lo hi extra)]) to))]
        [(3) (let ([last (document:line doc e)])
               (values (fxmax lo (document:line-start doc (document:line doc s)))
                       (if (fx< last (document:line doc hi)) (fxmin hi (document:line-start doc (fx+ last 1))) hi)))]
        [else (values s e)])))

  (define (select-between! view c a b mode dragging?)
    (let ([doc (buffers:document (views:buffer view))])
      (let-values ([(lo hi) (content-bounds view doc)])
        (let-values ([(s e) (mouse-range doc (fxmax lo (fxmin hi a)) (fxmax lo (fxmin hi b)) mode lo hi
                                         (word-characters-in (views:buffer view)))])
          (let ([mark (if (fx< b a) e s)] [point (if (fx< b a) s e)])
            (if (or (not (fx= mark point)) (and dragging? (views:cursor-mark c)))
                (begin
                  (views:set-cursor! c point mark)
                  (eq-hashtable-set! temporary c mark))
                (begin
                  (forget-temporary! c)
                  (views:set-cursor! c point #f))))))))

  (define-record-type drag
    (sealed #t)
    (fields view buffer anchor mode (mutable moved?) end))

  (define-table drag-keymap)

  (define drags (make-weak-eq-hashtable))

  (define (start-drag! client view position mode)
    (let ([old (eq-hashtable-ref drags client #f)])
      (when old ((drag-end old))))
    (let ([b (views:buffer view)])
      (eq-hashtable-set! drags client
        (make-drag view b (buffers:anchor b position) mode #f
                   (keys:push-keymap! client drag-keymap (lambda (found command) (eq? found drag-keymap)))))))

  (define (drag-in client view)
    (let ([d (eq-hashtable-ref drags client #f)])
      (and d (eq? (drag-view d) view) (eq? (drag-buffer d) (views:buffer view)) d)))

  (define (drag-anchor-position d) (buffers:anchor-position (drag-anchor d)))

  (define changed '())
  (define keeping-marks? #f)

  (define (note-change! buffer edit)
    (when (and (commands:this-command) (not (memq buffer changed)))
      (set! changed (cons buffer changed))))

  (define (shift-selected view)
    (filter (lambda (c) (temporary-mark? c (views:cursor-mark c))) (views:cursors view)))

  ;; Edits move marks, so the moved marks of the cursors that shift
  ;; selection marked are recorded again, or the next unshifted motion
  ;; would not clear them.
  (define (keep-changed-marks! view selected)
    (when (commands:this-command) (set! keeping-marks? #t))
    (for-each
      (lambda (c)
        (let ([m (views:cursor-mark c)])
          (when (and m (memq c (views:cursors view)))
            (eq-hashtable-set! temporary c m))))
      selected))

  (define (clear-changed-marks! command)
    (let ([bs changed] [keep? keeping-marks?])
      (set! changed '())
      (set! keeping-marks? #f)
      (unless keep?
        (for-each
          (lambda (b)
            (when (buffers:live? b)
              (for-each clear-marks! (views:showing b))))
          bs)))))

(import %internals)

(define (forward-word-position buffer position n)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'editing:forward-word-position "not a buffer" buffer))
  (unless (and (integer? position) (exact? position) (>= position 0))
    (assertion-violation 'editing:forward-word-position "not a position" position))
  (check-count 'editing:forward-word-position n)
  (check-main-thread 'editing:forward-word-position)
  (let ([doc (buffers:document buffer)])
    (unless (<= position (document:length doc))
      (assertion-violation 'editing:forward-word-position "not a position in the buffer" position))
    (words-from doc position n 1 (fx- (document:length doc) 1)
                (word-characters-in buffer))))

(commands:define-command (self-insert [n (commands:prefix-number)])
  "Inserts the character typed N times at each cursor."
  (check-nonnegative-count 'editing:self-insert n)
  (let ([char (keys:typed-char)] [view (command-view 'editing:self-insert)])
    (unless char
      (assertion-violation 'editing:self-insert "no character was typed"))
    (undo:amalgamate!)
    (insert-at-cursors! view (make-string n char) (delete-selection) (lambda (start end) end))))

(commands:define-command (newline [n (commands:prefix-number)])
  "Inserts N line breaks at each cursor."
  (check-nonnegative-count 'editing:newline n)
  (insert-at-cursors! (command-view 'editing:newline) (make-string n #\newline) (delete-selection)
    (lambda (start end) end)))

(commands:define-command (open-line [n (commands:prefix-number)])
  "Inserts N line breaks after each cursor, leaving the cursor before them."
  (check-nonnegative-count 'editing:open-line n)
  (insert-at-cursors! (command-view 'editing:open-line) (make-string n #\newline) #f
    (lambda (start end) start)))

(define (%delete-chars who view n)
  (let ([b (views:buffer view)] [primary (car (views:cursors view))] [stuck? #f])
    (replace-region-or! view (delete-selection)
      (lambda (c p)
        (let ([q (stops-from view p n)])
          (cond
            [(not (fx= q p))
             (buffers:replace! b (fxmin p q) (fxmax p q) "")
             (forget-temporary! c)
             (place-kept! view c (fxmin p q) #f)]
            [(and (eq? c primary) (not (= n 0))) (set! stuck? #t)]))))
    (when stuck? (edge-error who n))))

(commands:define-command (delete-backward-char [n (commands:prefix-number)])
  "Deletes N characters before each cursor."
  (check-count 'editing:delete-backward-char n)
  (let ([view (command-view 'editing:delete-backward-char)])
    (undo:amalgamate!)
    (%delete-chars 'editing:delete-backward-char view (- n))))

(commands:define-command (delete-char [n (commands:prefix-number)])
  "Deletes N characters after each cursor."
  (check-count 'editing:delete-char n)
  (let ([view (command-view 'editing:delete-char)])
    (undo:amalgamate!)
    (%delete-chars 'editing:delete-char view n)))

(commands:define-command (paste text)
  "Puts TEXT on the kill ring and yanks it."
  (unless (string? text)
    (assertion-violation 'editing:paste "not a string" text))
  (let ([view (command-view 'editing:paste)])
    (kill-ring:push! (list text))
    (yank-pieces! view (kill-ring:current) (delete-selection))))

(define (%move-chars who n)
  (let ([view (command-view who)])
    (move-cursors! who view n (lambda (c doc lo hi) (values (stops-from view (views:cursor-point c) n) #f)))))

(commands:define-command (forward-char [n (commands:prefix-number)])
  "Moves each cursor N characters forward."
  (check-count 'editing:forward-char n)
  (%move-chars 'editing:forward-char n))

(commands:define-command (backward-char [n (commands:prefix-number)])
  "Moves each cursor N characters back."
  (check-count 'editing:backward-char n)
  (%move-chars 'editing:backward-char (- n)))

(define (%move-lines who n)
  (let ([view (command-view who)])
    (move-cursors! who view n
      (line-motion-target n (and (memq (commands:last-command) (list next-line previous-line)) #t)))))

(commands:define-command (next-line [n (commands:prefix-number)])
  "Moves each cursor N lines down, keeping the column the run of line motions began at."
  (check-count 'editing:next-line n)
  (%move-lines 'editing:next-line n))

(commands:define-command (previous-line [n (commands:prefix-number)])
  "Moves each cursor N lines up, keeping the column the run of line motions began at."
  (check-count 'editing:previous-line n)
  (%move-lines 'editing:previous-line (- n)))

(commands:define-command (move-beginning-of-line)
  "Moves each cursor to the start of its line."
  (move-cursors! 'editing:move-beginning-of-line (command-view 'editing:move-beginning-of-line) 0
    (lambda (c doc lo hi)
      (values (document:line-start doc (document:line doc (views:cursor-point c))) #f))))

(commands:define-command (move-end-of-line)
  "Moves each cursor to the end of its line."
  (move-cursors! 'editing:move-end-of-line (command-view 'editing:move-end-of-line) 0
    (lambda (c doc lo hi)
      (values (end-of-line doc (document:line doc (views:cursor-point c)) hi) #f))))

;; No mark is set where point was, as Emacs pushes one: a mark here is
;; an active region, which typing would replace under delete-selection.
(define (%to-edge who end?)
  (let ([view (command-view who)])
    (for-each (lambda (c) (views:remove-cursor! view c)) (cdr (views:cursors view)))
    (move-cursors! who view 0 (lambda (c doc lo hi) (values (if end? hi lo) #f)))))

(commands:define-command (beginning-of-buffer)
  "Moves the primary cursor to the start of the buffer and removes the other cursors."
  (%to-edge 'editing:beginning-of-buffer #f))

(commands:define-command (end-of-buffer)
  "Moves the primary cursor to the end of the buffer and removes the other cursors."
  (%to-edge 'editing:end-of-buffer #t))

(define (%move-words who n)
  (let ([view (command-view who)] [extra (word-characters)])
    (move-cursors! who view n
      (lambda (c doc lo hi) (values (words-from doc (views:cursor-point c) n lo hi extra) #f)))))

(commands:define-command (forward-word [n (commands:prefix-number)])
  "Moves each cursor to the end of the Nth word after it."
  (check-count 'editing:forward-word n)
  (%move-words 'editing:forward-word n))

(commands:define-command (backward-word [n (commands:prefix-number)])
  "Moves each cursor to the start of the Nth word before it."
  (check-count 'editing:backward-word n)
  (%move-words 'editing:backward-word (- n)))

(commands:define-command (set-mark-command)
  "Sets each cursor's mark at its point; run again at once, clears the marks."
  (let ([view (command-view 'editing:set-mark-command)])
    (if (and (eq? (commands:last-command) set-mark-command) (views:mark view))
        (clear-marks! view)
        (set-marks! view views:cursor-point))))

(commands:define-command (exchange-point-and-mark)
  "Swaps each cursor's point and mark."
  (let ([view (command-view 'editing:exchange-point-and-mark)])
    (unless (views:mark view)
      (error 'editing:exchange-point-and-mark "the mark is not set"))
    (exchange-marks! view)))

(commands:define-command (mark-word [n (commands:prefix-number)])
  "Sets each cursor's mark at the end of the Nth word after point, or N words past its mark."
  (check-count 'editing:mark-word n)
  (let* ([view (command-view 'editing:mark-word)]
         [doc (buffers:document (views:buffer view))]
         [extra (word-characters)])
    (let-values ([(lo hi) (content-bounds view doc)])
      (set-marks! view
        (lambda (c) (words-from doc (or (views:cursor-mark c) (views:cursor-point c)) n lo hi extra))))))

(commands:define-command (mark-whole-buffer)
  "Puts the primary cursor's point at the start and its mark at the end of the buffer, and removes the other cursors."
  (let* ([view (command-view 'editing:mark-whole-buffer)]
         [doc (buffers:document (views:buffer view))])
    (for-each (lambda (c) (views:remove-cursor! view c)) (cdr (views:cursors view)))
    (let-values ([(lo hi) (content-bounds view doc)])
      (let ([c (car (views:cursors view))])
        (forget-temporary! c)
        (views:set-cursor! c lo hi)))))

(commands:define-command (kill-region)
  "Deletes each cursor's region and puts the regions on the kill ring as one entry."
  (let ([view (command-view 'editing:kill-region)])
    (check-regions 'editing:kill-region view)
    (kill-ranges! view (lambda (c) (values (views:cursor-mark c) (views:cursor-point c))) #t)))

(commands:define-command (kill-ring-save)
  "Puts each cursor's region on the kill ring as kill-region does, without deleting, and clears the marks."
  (let ([view (command-view 'editing:kill-ring-save)])
    (check-regions 'editing:kill-ring-save view)
    (kill-ranges! view (lambda (c) (values (views:cursor-mark c) (views:cursor-point c))) #f)
    (clear-marks! view)))

(define (%blank-token? t)
  (and (char? t) (or (char=? t #\space) (char=? t #\tab))))

(define (%blank? text)
  (for-all %blank-token? (string->list text)))

(commands:define-command (kill-line [n (and (commands:prefix-argument) (commands:prefix-number))])
  "Kills to the end of the line, or the line break when only spaces and tabs are left; with N, kills N lines."
  (unless (or (not n) (and (integer? n) (exact? n)))
    (assertion-violation 'editing:kill-line "not an exact integer or #f" n))
  (let* ([view (command-view 'editing:kill-line)]
         [doc (buffers:document (views:buffer view))])
    (let-values ([(lo hi) (content-bounds view doc)])
      (when (and (or (not n) (> n 0)) (fx>= (views:point view) hi))
        (error 'editing:kill-line "end of buffer"))
      (kill-ranges! view
        (lambda (c)
          (let* ([p (views:cursor-point c)] [line (document:line doc p)] [last (document:line doc hi)])
            (cond
              [(not n)
               (let ([e (end-of-line doc line hi)])
                 (values p (if (and (%blank? (document:text doc p e)) (fx< e hi)) (fx+ e 1) e)))]
              [(> n 0)
               (values p (if (> (+ line n) last) hi (document:line-start doc (+ line n))))]
              [else
               (values p (if (< (+ line n) 1) lo (fxmax lo (document:line-start doc (+ line n)))))])))
        #t))))

(define (%kill-words who n)
  (let* ([view (command-view who)]
         [doc (buffers:document (views:buffer view))]
         [extra (word-characters)])
    (let-values ([(lo hi) (content-bounds view doc)])
      (kill-ranges! view
        (lambda (c) (let ([p (views:cursor-point c)]) (values p (words-from doc p n lo hi extra))))
        #t))))

(commands:define-command (kill-word [n (commands:prefix-number)])
  "Kills from each cursor to the end of the Nth word after it."
  (check-count 'editing:kill-word n)
  (%kill-words 'editing:kill-word n))

(commands:define-command (backward-kill-word [n (commands:prefix-number)])
  "Kills from each cursor back to the start of the Nth word before it."
  (check-count 'editing:backward-kill-word n)
  (%kill-words 'editing:backward-kill-word (- n)))

(commands:define-command (yank)
  "Inserts the kill ring's current entry at each cursor, with the mark before it and point after it."
  (let ([view (command-view 'editing:yank)] [entry (kill-ring:current)])
    (unless entry
      (error 'editing:yank "the kill ring is empty"))
    (yank-pieces! view entry (delete-selection))))

(commands:define-command (yank-pop [n (commands:prefix-number)])
  "Replaces the text the previous command yanked with the entry N older in the kill ring."
  (check-count 'editing:yank-pop n)
  (let ([view (command-view 'editing:yank-pop)])
    (unless (and (memq (commands:last-command) (list yank yank-pop)) (yanked-in? view))
      (error 'editing:yank-pop "the previous command was not a yank"))
    (replace-yank! view (kill-ring:rotate! n))))

(commands:define-command (transpose-chars)
  "Swaps the characters before and after each cursor and moves past both; at a line's end, swaps the two before it."
  (let* ([view (command-view 'editing:transpose-chars)] [b (views:buffer view)])
    (for-each-cursor view
      (lambda (c p m)
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (let* ([end? (or (fx>= p hi) (eqv? (document:token doc p) #\newline))]
                   [x (if end? (fx- p 2) (fx- p 1))])
              (when (fx< x lo)
                (error 'editing:transpose-chars "beginning of buffer"))
              (let ([a (document:token doc x)] [z (document:token doc (fx+ x 1))])
                (unless (and (char? a) (char? z))
                  (error 'editing:transpose-chars "no two characters to transpose"))
                (buffers:replace! b x (fx+ x 2) (string z a))
                (move-kept! view c (if end? p (fx+ p 1)))))))))))

(commands:define-command (transpose-words)
  "Swaps the word before or around each cursor with the word after it, leaving the cursor after both."
  (let* ([view (command-view 'editing:transpose-words)] [b (views:buffer view)] [extra (word-characters)])
    (for-each-cursor view
      (lambda (c p m)
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (let* ([start1 (words-from doc p -1 lo hi extra)]
                   [end1 (words-from doc start1 1 lo hi extra)]
                   [end2 (words-from doc end1 1 lo hi extra)]
                   [start2 (words-from doc end2 -1 lo hi extra)]
                   [first (cons (fxmin start1 end1) (fxmax start1 end1))]
                   [second (cons (fxmin start2 end2) (fxmax start2 end2))]
                   [a (if (fx> (car first) (car second)) second first)]
                   [z (if (fx> (car first) (car second)) first second)]
                   [ta (and (fx<= (cdr a) (car z)) (pure-text doc (car a) (cdr a)))]
                   [tz (and ta (pure-text doc (car z) (cdr z)))])
              (unless tz
                (error 'editing:transpose-words "no two words to transpose"))
              (unless (string=? ta tz)
                (buffers:replace! b (car z) (cdr z) ta)
                (buffers:replace! b (car a) (cdr a) tz))
              (move-kept! view c (cdr z)))))))))

(define (%line-text-range b doc line hi)
  (let ([e (end-of-line doc line hi)])
    (values (fxmin e (first-stop b (fxmax 1 (document:line-start doc line)))) e)))

(commands:define-command (transpose-lines)
  "Swaps each cursor's line with the line before it and moves to the next line."
  (let* ([view (command-view 'editing:transpose-lines)] [b (views:buffer view)])
    (for-each-cursor view
      (lambda (c p m)
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (let* ([line (document:line doc p)]
                   [first-line (document:line doc lo)]
                   [upper (if (fx= line first-line) line (fx- line 1))]
                   [lower (fx+ upper 1)])
              (when (fx> lower (document:line doc hi))
                (error 'editing:transpose-lines "no two lines to transpose"))
              (let-values ([(s1 e1) (%line-text-range b doc upper hi)]
                           [(s2 e2) (%line-text-range b doc lower hi)])
                (buffers:replace! b s2 e2 (document:slice doc s1 e1))
                (buffers:replace! b s1 e1 (document:slice doc s2 e2))
                (let ([doc (buffers:document b)])
                  (let-values ([(lo hi) (content-bounds view doc)])
                    (move-kept! view c
                      (if (fx< lower (document:line doc hi)) (document:line-start doc (fx+ lower 1)) hi))))))))))))

(define (%case-words who n convert)
  (let* ([view (command-view who)] [b (views:buffer view)] [extra (word-characters)])
    (for-each-cursor view
      (lambda (c p m)
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (let* ([q (words-from doc p n lo hi extra)]
                   [delta (recase! b (fxmin p q) (fxmax p q) convert)])
              (move-kept! view c (fx+ (fxmax p q) delta)))))))))

(define (%case-region who convert)
  (let* ([view (command-view who)] [b (views:buffer view)])
    (check-regions who view)
    (for-each-cursor view
      (lambda (c p m)
        (let* ([s (fxmin p m)] [e (fxmax p m)] [delta (recase! b s e convert)])
          (if (fx= p e)
              (place-kept! view c (fx+ e delta) s)
              (place-kept! view c s (fx+ e delta))))))))

(commands:define-command (upcase-word [n (commands:prefix-number)])
  "Converts the text from each cursor to the end of the Nth word to upper case and moves past it."
  (check-count 'editing:upcase-word n)
  (%case-words 'editing:upcase-word n string-upcase))

(commands:define-command (downcase-word [n (commands:prefix-number)])
  "Converts the text from each cursor to the end of the Nth word to lower case and moves past it."
  (check-count 'editing:downcase-word n)
  (%case-words 'editing:downcase-word n string-downcase))

(commands:define-command (capitalize-word [n (commands:prefix-number)])
  "Capitalizes each word from each cursor to the end of the Nth word and moves past it."
  (check-count 'editing:capitalize-word n)
  (%case-words 'editing:capitalize-word n (capitalizer (word-characters))))

(commands:define-command (upcase-region)
  "Converts each cursor's region to upper case."
  (%case-region 'editing:upcase-region string-upcase))

(commands:define-command (downcase-region)
  "Converts each cursor's region to lower case."
  (%case-region 'editing:downcase-region string-downcase))

(commands:define-command (capitalize-region)
  "Capitalizes each word in each cursor's region."
  (%case-region 'editing:capitalize-region (capitalizer (word-characters))))

(define (%indentation-end doc start end)
  (let loop ([p start])
    (if (and (fx< p end) (%blank-token? (document:token doc p))) (loop (fx+ p 1)) p)))

(define (%blanks-start doc end lo)
  (let loop ([p end])
    (if (and (fx> p lo) (%blank-token? (document:token doc (fx- p 1)))) (loop (fx- p 1)) p)))

(define (%region-lines b doc p m hi)
  (if (nonempty-region? p m)
      (let* ([low (fxmin p m)] [high (fxmax p m)]
             [first (document:line doc low)] [last (document:line doc high)])
        (let-values ([(s e) (%line-text-range b doc last hi)])
          (values first (if (and (fx> last first) (fx<= high s)) (fx- last 1) last))))
      (let ([line (document:line doc p)]) (values line line))))

(commands:define-command (back-to-indentation)
  "Moves each cursor to the first character of its line that is not a space or tab; a cursor already there goes to the start of the line."
  (let* ([view (command-view 'editing:back-to-indentation)] [b (views:buffer view)])
    (move-cursors! 'editing:back-to-indentation view 0
      (lambda (c doc lo hi)
        (let ([p (views:cursor-point c)])
          (let-values ([(s e) (%line-text-range b doc (document:line doc p) hi)])
            (let ([indented (%indentation-end doc s e)])
              (values (if (fx= p indented) s indented) #f))))))))

(commands:define-command (kill-whole-line [n (commands:prefix-number)])
  "Kills each cursor's line with its line break; with N, N lines from it, or for a negative N, -N lines ending at it with the line break before them; with 0, the line without its break."
  (check-count 'editing:kill-whole-line n)
  (let* ([view (command-view 'editing:kill-whole-line)] [b (views:buffer view)] [doc (buffers:document b)])
    (let-values ([(lo hi) (content-bounds view doc)])
      (let ([first (document:line doc lo)] [last (document:line doc hi)])
        (define (ends-at p)
          (let ([line (document:line doc p)])
            (let-values ([(s e) (%line-text-range b doc line hi)])
              (cond
                [(> n 0)
                 (values (fxmax lo s)
                         (if (> (+ line n) last) hi (fxmin hi (document:line-start doc (+ line n)))))]
                [(= n 0) (values (fxmax lo s) e)]
                [else (values e (if (< (+ line n) first) lo (end-of-line doc (+ line n) hi)))]))))
        (let-values ([(s e) (%line-text-range b doc (document:line doc (views:point view)) hi)])
          (cond
            [(and (> n 0) (fx>= s hi)) (error 'editing:kill-whole-line "end of buffer")]
            [(and (< n 0) (fx<= e lo)) (error 'editing:kill-whole-line "beginning of buffer")]))
        (kill-ranges! view (lambda (c) (ends-at (views:cursor-point c))) #t)))))

(define (%space-between? doc start end lo hi)
  (let ([before (and (fx> start lo) (document:token doc (fx- start 1)))]
        [after (and (fx< end hi) (document:token doc end))])
    (and (char? before) (char? after)
         (not (char=? before #\newline))
         (not (char=? after #\newline))
         (not (eq? (char-general-category before) 'Ps))
         (not (eq? (char-general-category after) 'Pe)))))

(commands:define-command (delete-indentation)
  "Joins each cursor's line to the line before it, replacing the line break and the spaces and tabs around it with one space, or none after an opening bracket, before a closing one, or beside an empty line."
  (let* ([view (command-view 'editing:delete-indentation)] [b (views:buffer view)])
    (for-each-cursor view
      (lambda (c p m)
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (let ([line (document:line doc p)])
              (when (fx> line (document:line doc lo))
                (let-values ([(s e) (%line-text-range b doc line hi)])
                  (let ([start (%blanks-start doc (fx- (document:line-start doc line) 1) lo)]
                        [end (%indentation-end doc s e)])
                    (buffers:replace! b start end (if (%space-between? doc start end lo hi) " " ""))
                    (move-kept! view c start)))))))))))

(commands:define-command (duplicate-dwim [n (commands:prefix-number)])
  "Inserts N copies of each cursor's region after it, or, at a cursor with no region, N copies of its line after the line, leaving the cursor and its region where they were."
  (check-count 'editing:duplicate-dwim n)
  (let* ([view (command-view 'editing:duplicate-dwim)] [b (views:buffer view)] [selected (shift-selected view)])
    (when (> n 0)
      (for-each-cursor view
        (lambda (c p m)
          (if (nonempty-region? p m)
              (let ([piece (kill-ring:piece b (fxmin p m) (fxmax p m))])
                (let loop ([at (fxmax p m)] [k n])
                  (unless (= k 0)
                    (loop (kill-ring:insert! b at piece) (- k 1)))))
              (let ([doc (buffers:document b)])
                (let-values ([(lo hi) (content-bounds view doc)])
                  (let-values ([(s e) (%line-text-range b doc (document:line doc p) hi)])
                    (let ([piece (kill-ring:piece b s e)])
                      (let loop ([at e] [k n])
                        (unless (= k 0)
                          (buffers:replace! b at at "\n")
                          (loop (kill-ring:insert! b (fx+ at 1) piece) (- k 1)))))))))
          (place-kept! view c p m)))
      (keep-changed-marks! view selected))))

(define (%line-text-start b doc line hi)
  (let-values ([(s e) (%line-text-range b doc line hi)]) s))

;; The neighbouring lines move around the block rather than the block
;; around them, so no cursor in the block is deleted with its text, and
;; cursors that would meet do not merge. They are inserted before they
;; are deleted, so an edit the buffer refuses leaves a copy of a line
;; rather than losing one.
(define (%move-block-down! b doc first last steps hi)
  (let* ([start (%line-text-start b doc first hi)]
         [end (end-of-line doc last hi)]
         [next (%line-text-start b doc (fx+ last 1) hi)]
         [following-end (end-of-line doc (fx+ last steps) hi)]
         [following (kill-ring:piece b next following-end)]
         [between (kill-ring:piece b end next)]
         [shift (fx- (kill-ring:insert! b (kill-ring:insert! b start following) between) start)])
    (buffers:replace! b (fx+ end shift) (fx+ following-end shift) "")))

(define (%move-block-up! b doc first last steps hi)
  (let* ([start (%line-text-start b doc first hi)]
         [end (end-of-line doc last hi)]
         [previous (%line-text-start b doc (fx- first steps) hi)]
         [previous-end (end-of-line doc (fx- first 1) hi)]
         [preceding (kill-ring:piece b previous previous-end)]
         [between (kill-ring:piece b previous-end start)])
    (kill-ring:insert! b (kill-ring:insert! b end between) preceding)
    (buffers:replace! b previous start "")))

(define-record-type (%line-move %make-line-move %line-move?)
  (sealed #t)
  (fields first last steps))

(define-record-type (%cursor-place %make-cursor-place %cursor-place?)
  (sealed #t)
  (fields cursor point mark))

;; Blocks closer than the distance moved would pass through each other,
;; so they move as one.
(define (%line-blocks b doc cursors hi distance)
  (let loop ([blocks (list-sort (lambda (x y) (fx< (car x) (car y)))
                       (map (lambda (c)
                              (let-values ([(first last) (%region-lines b doc (views:cursor-point c) (views:cursor-mark c) hi)])
                                (cons first last)))
                            cursors))]
             [merged '()])
    (cond
      [(null? blocks) (reverse merged)]
      [(and (pair? merged) (fx<= (fx- (caar blocks) (cdar merged)) distance))
       (loop (cdr blocks) (cons (cons (caar merged) (fxmax (cdar merged) (cdar blocks))) (cdr merged)))]
      [else (loop (cdr blocks) (cons (car blocks) merged))])))

(define (%line-place b doc q hi)
  (let ([line (document:line doc q)])
    (cons line (fx- q (%line-text-start b doc line hi)))))

;; A place is a line and a column, so a region that ends at the start of
;; the line after a block still ends after the block once it has moved.
(define (%move-line-blocks! who n)
  (let* ([view (command-view who)] [b (views:buffer view)] [doc (buffers:document b)]
         [down? (> n 0)] [distance (min (abs n) (document:length doc))]
         [cursors (views:cursors view)] [selected (shift-selected view)])
    (let-values ([(lo hi) (content-bounds view doc)])
      (let* ([first (document:line doc lo)] [last (document:line doc hi)]
             [moves (map (lambda (block)
                           (let ([a (car block)] [z (cdr block)])
                             (%make-line-move a z (fxmin distance (if down? (fx- last z) (fx- a first))))))
                         (%line-blocks b doc cursors hi distance))]
             [places (map (lambda (c)
                            (let ([m (views:cursor-mark c)])
                              (%make-cursor-place c (%line-place b doc (views:cursor-point c) hi)
                                                  (and m (%line-place b doc m hi)))))
                          cursors)])
        (define (move-of line)
          (find (lambda (move) (fx<= (%line-move-first move) line (fx+ (%line-move-last move) 1))) moves))
        (unless (= n 0)
          (for-each
            (lambda (move)
              (let ([steps (%line-move-steps move)])
                (unless (fx= steps 0)
                  (let ([doc (buffers:document b)])
                    (let-values ([(lo hi) (content-bounds view doc)])
                      ((if down? %move-block-down! %move-block-up!)
                       b doc (%line-move-first move) (%line-move-last move) steps hi))))))
            (if down? (reverse moves) moves))
          (let ([doc (buffers:document b)])
            (let-values ([(lo hi) (content-bounds view doc)])
              (define (moved place)
                (let* ([line (car place)]
                       [move (move-of line)]
                       [to (cond
                             [(not move) line]
                             [down? (fx+ line (%line-move-steps move))]
                             [else (fx- line (%line-move-steps move))])])
                  (if (fx> to (document:line doc hi))
                      hi
                      (fxmax lo (fxmin hi (fx+ (%line-text-start b doc to hi) (cdr place)))))))
              (for-each
                (lambda (place)
                  (let ([m (%cursor-place-mark place)])
                    (place-kept! view (%cursor-place-cursor place)
                                 (moved (%cursor-place-point place)) (and m (moved m)))))
                places)))
          (keep-changed-marks! view selected)
          (let ([primary (move-of (car (%cursor-place-point (car places))))])
            (when (and primary (fx= (%line-move-steps primary) 0))
              (edge-error who n))))))))

(commands:define-command (move-line-down [n (commands:prefix-number)])
  "Moves each cursor's line, or the lines its region touches, N lines down, with the cursor and region."
  (check-count 'editing:move-line-down n)
  (%move-line-blocks! 'editing:move-line-down n))

(commands:define-command (move-line-up [n (commands:prefix-number)])
  "Moves each cursor's line, or the lines its region touches, N lines up, with the cursor and region."
  (check-count 'editing:move-line-up n)
  (%move-line-blocks! 'editing:move-line-up (- n)))

(define (%open-line who below?)
  (let* ([view (command-view who)] [b (views:buffer view)])
    (for-each-cursor view
      (lambda (c p m)
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (let-values ([(s e) (%line-text-range b doc (document:line doc p) hi)])
              (let* ([indentation (document:text doc s (%indentation-end doc s e))]
                     [width (string-length indentation)])
                (let-values ([(at text point)
                              (if below?
                                  (values e (string-append "\n" indentation) (fx+ e 1 width))
                                  (values s (string-append indentation "\n") (fx+ s width)))])
                  (forget-temporary! c)
                  (buffers:replace! b at at text)
                  (place-kept! view c point #f))))))))))

(commands:define-command (open-line-below)
  "Starts a line after each cursor's line, indented as it, and moves the cursor there."
  (%open-line 'editing:open-line-below #t))

(commands:define-command (open-line-above)
  "Starts a line before each cursor's line, indented as it, and moves the cursor there."
  (%open-line 'editing:open-line-above #f))

;; As in Emacs, text the buffer refuses to change is left as it is and
;; the rest is trimmed.
(define (%delete-unless-refused! b start end)
  (guard (c [(buffers:refused? c) (void)])
    (buffers:replace! b start end "")
    (void)))

(define (%trim-lines! b doc from to lo hi)
  (let loop ([line (document:line doc to)])
    (when (fx>= line (document:line doc from))
      (let-values ([(s e) (%line-text-range b doc line hi)])
        (let ([start (%blanks-start doc e (fxmax lo s))])
          (when (and (fx< start e) (fx< from e) (fx<= e to))
            (%delete-unless-refused! b start e))))
      (loop (fx- line 1)))))

(define (%trim-final-lines! b view)
  (let ([doc (buffers:document b)])
    (let-values ([(lo hi) (content-bounds view doc)])
      (when (fx= hi (fx- (document:length doc) 1))
        (let ([start (let loop ([p hi])
                       (if (and (fx> p lo) (eqv? (document:token doc (fx- p 1)) #\newline)) (loop (fx- p 1)) p))])
          (when (fx>= (fx- hi start) 2)
            (%delete-unless-refused! b (fx+ start 1) hi)))))))

(commands:define-command (delete-trailing-whitespace)
  "Deletes the spaces and tabs at the ends of the lines in each cursor's region or, when no cursor has a region, in the whole buffer and the empty lines at its end."
  (let* ([view (command-view 'editing:delete-trailing-whitespace)] [b (views:buffer view)])
    (if (exists (lambda (c) (nonempty-region? (views:cursor-point c) (views:cursor-mark c)))
                (views:cursors view))
        (for-each-cursor view
          (lambda (c p m)
            (when (nonempty-region? p m)
              (let ([doc (buffers:document b)])
                (let-values ([(lo hi) (content-bounds view doc)])
                  (%trim-lines! b doc (fxmin p m) (fxmax p m) lo hi))))))
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (%trim-lines! b doc lo hi lo hi))
          (%trim-final-lines! b view)))))

;; The lines go in again after the old ones before those are deleted, so
;; an edit the buffer refuses leaves a copy of a line rather than losing
;; one.
(define (%reorder-lines! b ranges order)
  (let ([lines (map (lambda (r) (kill-ring:piece b (car r) (cdr r))) order)]
        [separators (let loop ([rs ranges] [acc '()])
                      (if (null? (cdr rs))
                          (reverse acc)
                          (loop (cdr rs) (cons (kill-ring:piece b (cdar rs) (caadr rs)) acc))))])
    (let ([inserted (kill-ring:insert! b (cdar (last-pair ranges)) (car (last-pair separators)))])
      (let loop ([at inserted] [lines lines] [separators separators])
        (let ([at (kill-ring:insert! b at (car lines))])
          (unless (null? separators)
            (loop (kill-ring:insert! b at (car separators)) (cdr lines) (cdr separators)))))
      (buffers:replace! b (caar ranges) inserted ""))))

(commands:define-command (sort-lines)
  "Sorts the lines each cursor's region touches by their text."
  (let* ([view (command-view 'editing:sort-lines)] [b (views:buffer view)])
    (check-regions 'editing:sort-lines view)
    (for-each-cursor view
      (lambda (c p m)
        (let ([doc (buffers:document b)])
          (let-values ([(lo hi) (content-bounds view doc)])
            (let-values ([(first last) (%region-lines b doc p m hi)])
              (let* ([ranges (let loop ([line last] [acc '()])
                               (if (fx< line first)
                                   acc
                                   (let-values ([(s e) (%line-text-range b doc line hi)])
                                     (loop (fx- line 1) (cons (cons s e) acc)))))]
                     [keyed (map (lambda (r) (cons (document:text doc (car r) (cdr r)) r)) ranges)]
                     [sorted (map cdr (list-sort (lambda (x y) (string<? (car x) (car y))) keyed))])
                (unless (for-all eq? ranges sorted)
                  (%reorder-lines! b ranges sorted))
                (place-kept! view c p m)))))))))

(define (%mouse-view who event)
  (unless (keys:event? event)
    (assertion-violation who "not an event" event))
  (let ([view (views:posn-view (keys:event-start event))])
    (and view (views:buffer view)
         (let ([node (layout:view-node view)]) (and node (not (layout:locked? node))))
         view)))

(define (%in-view view act)
  (layout:select! view)
  (views:call-with-view view
    (lambda ()
      (for-each (lambda (c) (views:remove-cursor! view c)) (cdr (views:cursors view)))
      (act (car (views:cursors view))))))

(commands:define-command (mouse-drag-region [event (keys:command-event)])
  "Selects the view pressed in, clears the mark unless run shift-translated, and moves point to the press; a second or third press selects the word or line there. Dragging then selects from the press."
  (let ([view (%mouse-view 'editing:mouse-drag-region event)])
    (when view
      (%in-view view
        (lambda (c)
          (let ([p (views:posn-point (keys:event-start event))])
            (when p
              (if (keys:shift-translated?)
                  (begin
                    (place! c p #t)
                    (start-drag! (web:current-client) view (views:cursor-mark c) 1))
                  (let ([mode (keys:event-clicks event)])
                    (clear-marks! view)
                    (select-between! view c p p mode #f)
                    (start-drag! (web:current-client) view p mode))))))))))

(commands:define-command (mouse-drag-movement [event (keys:command-event)])
  "Moves point to where the held button moved and, once it differs from the press, sets the mark at the press, by the press's words or lines."
  (unless (keys:event? event)
    (assertion-violation 'editing:mouse-drag-movement "not an event" event))
  (let* ([posn (keys:event-start event)] [view (views:posn-view posn)] [p (views:posn-point posn)]
         [d (and view p (drag-in (web:current-client) view))])
    (when d
      (views:call-with-view view
        (lambda ()
          (let ([a (drag-anchor-position d)])
            (when (or (drag-moved? d) (not (fx= p a)))
              (drag-moved?-set! d #t)
              (select-between! view (car (views:cursors view)) a p (drag-mode d) #t))))))))

(commands:define-command (mouse-set-region [event (keys:command-event)])
  "Sets the region from the drag's start to its end, by the press's words or lines; with no end position, to point. An empty region is taken as a click."
  (let ([view (%mouse-view 'editing:mouse-set-region event)])
    (when view
      (%in-view view
        (lambda (c)
          (let* ([d (drag-in (web:current-client) view)]
                 [start (if d (drag-anchor-position d) (views:posn-point (keys:event-start event)))])
            (when start
              (select-between! view c start (or (views:posn-point (keys:event-end event)) (views:cursor-point c))
                               (if d (drag-mode d) (keys:event-clicks event)) #f))))))))

(commands:define-command (mouse-set-point [event (keys:command-event)])
  "Selects the view clicked in and moves point there, clearing the mark unless run shift-translated; after a second or third press, keeps the word or line selected."
  (let ([view (%mouse-view 'editing:mouse-set-point event)])
    (when view
      (%in-view view
        (lambda (c)
          (let ([p (views:posn-point (keys:event-start event))] [mode (keys:event-clicks event)])
            (when p
              (cond
                [(keys:shift-translated?) (place! c p #t)]
                [(fx= mode 1) (clear-marks! view) (views:set-cursor! c p #f)]
                [else
                 (let ([d (drag-in (web:current-client) view)])
                   (select-between! view c (if d (drag-anchor-position d) p) p mode #f))]))))))))

(define (%quit-clears-marks quit)
  (let ([v (views:current)])
    (when (and v (views:buffer v)) (clear-marks! v)))
  (quit))

(add-hook! buffers:after-edit note-change!)
(add-hook! commands:after-command clear-changed-marks!)
(add-hook! commands:after-command remember-kill!)
(advice-add! keys:keyboard-quit %quit-clears-marks)

(keys:bind! keys:global "<printing-char>" self-insert)
(keys:bind! keys:global "SPC" self-insert)
(keys:bind! keys:global "RET" newline)
(keys:bind! keys:global "C-o" open-line)
(keys:bind! keys:global "DEL" delete-backward-char)
(keys:bind! keys:global "C-d" delete-char)
(keys:bind! keys:global "<delete>" delete-char)
(keys:bind! keys:global "C-f" forward-char)
(keys:bind! keys:global "<right>" forward-char)
(keys:bind! keys:global "C-b" backward-char)
(keys:bind! keys:global "<left>" backward-char)
(keys:bind! keys:global "C-n" next-line)
(keys:bind! keys:global "<down>" next-line)
(keys:bind! keys:global "C-p" previous-line)
(keys:bind! keys:global "<up>" previous-line)
(keys:bind! keys:global "C-a" move-beginning-of-line)
(keys:bind! keys:global "<home>" move-beginning-of-line)
(keys:bind! keys:global "C-e" move-end-of-line)
(keys:bind! keys:global "<end>" move-end-of-line)
(keys:bind! keys:global "M-<" beginning-of-buffer)
(keys:bind! keys:global "M->" end-of-buffer)
(keys:bind! keys:global "M-f" forward-word)
(keys:bind! keys:global "C-<right>" forward-word)
(keys:bind! keys:global "M-<right>" forward-word)
(keys:bind! keys:global "M-b" backward-word)
(keys:bind! keys:global "C-<left>" backward-word)
(keys:bind! keys:global "M-<left>" backward-word)
(keys:bind! keys:global "C-SPC" set-mark-command)
(keys:bind! keys:global "C-@" set-mark-command)
(keys:bind! keys:global "C-x C-x" exchange-point-and-mark)
(keys:bind! keys:global "M-@" mark-word)
(keys:bind! keys:global "C-x h" mark-whole-buffer)
(keys:bind! keys:global "C-w" kill-region)
(keys:bind! keys:global "M-w" kill-ring-save)
(keys:bind! keys:global "C-k" kill-line)
(keys:bind! keys:global "M-d" kill-word)
(keys:bind! keys:global "C-<delete>" kill-word)
(keys:bind! keys:global "M-DEL" backward-kill-word)
(keys:bind! keys:global "C-DEL" backward-kill-word)
(keys:bind! keys:global "C-y" yank)
(keys:bind! keys:global "M-y" yank-pop)
(keys:bind! keys:global "C-t" transpose-chars)
(keys:bind! keys:global "M-t" transpose-words)
(keys:bind! keys:global "C-x C-t" transpose-lines)
(keys:bind! keys:global "M-u" upcase-word)
(keys:bind! keys:global "M-l" downcase-word)
(keys:bind! keys:global "M-c" capitalize-word)
(keys:bind! keys:global "C-x C-u" upcase-region)
(keys:bind! keys:global "C-x C-l" downcase-region)
(keys:bind! keys:global "M-m" back-to-indentation)
(keys:bind! keys:global "C-S-DEL" kill-whole-line)
(keys:bind! keys:global "M-^" delete-indentation)
(keys:bind! keys:global "M-<up>" move-line-up)
(keys:bind! keys:global "M-<down>" move-line-down)
(keys:bind! keys:global "C-RET" open-line-below)
(keys:bind! keys:global "C-S-RET" open-line-above)
(keys:bind! keys:global "<down-mouse-1>" mouse-drag-region)
(keys:bind! keys:global "<mouse-1>" mouse-set-point)
(keys:bind! keys:global "<drag-mouse-1>" mouse-set-region)
(keys:bind! drag-keymap "<mouse-movement>" mouse-drag-movement)
