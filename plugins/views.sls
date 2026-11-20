#!tuna
(import (buffers) (document) (web) (haml) (keys) (commands) (faces) (views height-map))

(define-option drawn-screens 2 (lambda (v) (and (real? v) (finite? v) (> v 0)))
  "How many view heights a view keeps drawn beyond each edge of what is in view.")
(define-option scroll-margin 0 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many of a client's line heights a view keeps between the primary cursor and its top and bottom edges, at most a quarter of the view's height.")
(define-option wrap-lines #t boolean?
  "Whether a line longer than the view wraps onto several screen lines.")
(define-option cursor-visible #t boolean?
  "Whether a view draws its cursors.")
(define-option hand-scroll-moves-point #t boolean?
  "Whether a scroll made with the pointer that leaves point outside the view moves point into it.")
(define-option column-number #f boolean?
  "Whether views:describe-line shows the column after the line.")
(define-option point-after-insertion? #f boolean?
  "Whether a view's point where text is inserted stays after the text, and the view follows it; read when the view shows the buffer, and set locally by a buffer's mode.")

(define-table span-properties
  "Maps a key of a span's value to a procedure that returns attributes for the span's element.")

(define-table span-sources
  "Maps a procedure of a view, a client and the start and end of the run drawn, which returns spans as buffers:spans does, to the priority of a layer they draw as.")

(define-table position-describers
  "Maps a kind's constructor to a procedure of a node of the kind and a view that describes where the view's point is in the node.")

(define-enumeration switch-reason (previous next bury kill) switch-reasons)

(define-option skipped-buffer-predicate (lambda (view buffer reason) #f) procedure?
  "A procedure of a view, a buffer and a switch reason that returns true for a buffer views:previous-buffer!, views:next-buffer!, views:replace-buffer! or a killed buffer's views must not show in that view.")

(define-enumeration align (top center bottom) %alignments)

(define-enumeration scroller-align (start end center nearest) %scroller-alignments)

(define-enumeration axis (row column) %axes)

(module %internals
  (check-main-thread check-view check-cursor check-node check-option check-position check-live-buffer shown-buffer
   current-view make-new-view! find-view views-showing bound-buffer show-buffer! drop-view! with-view-bound
   switch-buffer! previous-buffer-in! next-buffer-in! replace-buffer-in! previous-buffers-of last-point-of set-last-point-of! previewing-in?
   preview-in! end-preview-in!
   view-record? view-record-dropped? view-record-id view-record-cursors view-record-cursors-set!
   view-record-folds-set! view-record-narrowing-set! view-record-shown-count top-position body-size-in
   cursor-record? cursor-record-view cursor-record-goal cursor-record-goal-set!
   spot-position point-of mark-of set-cursor-spots! move-point! add-cursor-at! primary-moved! mark-dirty!
   bounds-of live-folds add-fold! narrow-view! widen-view! stop-after stop-before
   set-view-option! remove-view-option! state-entry view-record-states view-record-states-set!
   scroll-to-place! estimate-range! draw-view current-context context-view context-client in-line? make-context children-html drawing?
   atom-view-of keymaps-at note-edit note-kill after-batch scroll-report mouse-item posn-keymaps forget-client!
   posn-record? make-posn-record posn-record-view posn-record-point posn-record-node posn-record-keymaps
   posn-record-x posn-record-y posn-record-column posn-record-row keymap-id marked-keymaps click-state
   view-client when-measured! scroll-by! recenter! region-ranges-of
   face-attributes title-attributes text-spans-html
   anchor-record? anchor-record-id anchor-record-view anchor-record-spot anchor-record-gone?
   new-anchor! forget-anchor! anchor-of-id anchor-drawn-for?
   scroller-record? scroller-record-id scroller-record-dropped? make-new-scroller! set-scroller-place!
   scroller-client scroller-record-clients scroller-state-number scroller-state-reported scroller-state-in-view
   scroller-state-whole
   scroller-record-item scroller-record-align scroller-record-focus forget-scroller! scroller-report)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  ;; Positions a view keeps are anchors while it shows a live buffer, and
  ;; plain numbers while it waits for one, as views restored from saved
  ;; data do until their buffer is made.
  (define-record-type view-record
    (sealed #t)
    (fields id (mutable name) (mutable buffer) (mutable cursors) (mutable place)
            (mutable moved?) (mutable moved-by) (mutable moved-last) (mutable placed-by) clients
            (mutable folds) (mutable narrowing) (mutable options) (mutable states)
            (mutable saved?) (mutable host) (mutable dropped?) (mutable shown-count)
            devices (mutable items) (mutable items-key) (mutable drawn) (mutable next-item)
            (mutable previous) (mutable next) (mutable preview))
    (protocol
      (lambda (new)
        (lambda (id name buffer place folds narrowing saved?)
          (new id name buffer '() place #f #f 'followed #f (make-eq-hashtable)
               folds narrowing '() '() saved? #f #f 0 (make-hashtable string-hash string=?) (make-eqv-hashtable) #f 0 1
               '() '() #f)))))

  (define-record-type place
    (sealed #t)
    (fields kind spot offset height left))

  (define (follow-place) (make-place 'follow #f 0.0 0.0 0.0))

  (define-record-type client-view
    (sealed #t)
    (fields device (mutable number) (mutable placement) (mutable own) (mutable measured) (mutable facts)
            (mutable from) (mutable to) (mutable sizer) (mutable scale) (mutable map)
            (mutable owed) (mutable reported) (mutable drawn-batch) (mutable sized))
    (protocol
      (lambda (new)
        (lambda (device)
          (new device 0 #f #f #f #f #f #f #f 1.0 #f #f 0 -1 #f)))))

  (define-record-type facts
    (sealed #t)
    (fields width height line-height char-width start end at-end? below))

  ;; The size a client of the device last measured is kept for a new
  ;; client of it, as after a reload, to start from.
  (define-record-type device-view
    (sealed #t)
    (fields (mutable maps) (mutable wrap?) (mutable width) (mutable height)))

  ;; An item's id is its anchor's number in its view, kept while the
  ;; anchor stays at an item's start, so the browser's morph keeps the
  ;; item's element through scrolls and edits elsewhere.
  (define-record-type item-anchor
    (sealed #t)
    (fields name spot (mutable batch) (mutable last)))

  (define-record-type cursor-record
    (sealed #t)
    (fields view (mutable point) (mutable mark) (mutable goal)))

  (define-record-type view-option
    (sealed #t)
    (fields option value owner))

  (define-record-type anchor-record
    (sealed #t)
    (fields id view spot (mutable gone?)))

  (define anchors-by-id (make-eqv-hashtable))
  (define anchors-by-view (make-eq-hashtable))

  (define-record-type scroller-record
    (sealed #t)
    (fields id (mutable item) (mutable align) (mutable focus) clients on-rest (mutable dropped?)))

  (define-record-type scroller-state
    (sealed #t)
    (fields (mutable number) (mutable reported) (mutable in-view) (mutable whole)))

  (define scrollers (make-eqv-hashtable))

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

  (define (views-showing b) (hashtable-ref by-buffer b '()))

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

  (define (point-spot b p)
    (make-spot b p (and b (buffers:with-buffer b (point-after-insertion?)))))

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
      (cursor-record-point-set! c
        (if (fixnum? (cursor-record-point c)) (point-spot b point) (move-spot (cursor-record-point c) b point #f)))
      (cursor-record-mark-set! c
        (and mark (let ([m (cursor-record-mark c)])
                    (if m (move-spot m b mark #f) (make-spot b mark #f)))))
      (mark-dirty!)))

  ;; The follow uses what the browser of the client whose command moved
  ;; point measured.
  (define (primary-moved! v)
    (with-interrupts-disabled
      (view-record-moved?-set! v #t)
      (view-record-moved-by-set! v (web:current-client)))
    (let ([b (view-record-buffer v)])
      (when b
        (eq-hashtable-set! movers b v)
        (set! history-dirty? #t))))

  ;; Before a device has measured a view at its width, nothing says how
  ;; many items fill it, so its first screen draws this many on each side.
  (define initial-drawn-items 200)

  ;; Placement numbers start at a random base, so a page that applied a
  ;; number before this module reloaded never takes a new placement for
  ;; one it has applied.
  (define last-placement
    (call-with-port (open-file-input-port "/dev/urandom")
      (lambda (p) (bytevector-uint-ref (get-bytevector-n p 6) 0 (endianness little) 6))))

  (define (send-placement! cs place)
    (with-interrupts-disabled
      (set! last-placement (fx+ last-placement 1))
      (client-view-number-set! cs last-placement)
      (client-view-placement-set! cs place)))

  (define (next-number!)
    (with-interrupts-disabled
      (set! last-placement (fx+ last-placement 1))
      last-placement))

  ;; Anchors are numbered from the placements' random base, so a number
  ;; kept in another plugin's data from before this module reloaded never
  ;; names an anchor in other text.
  (define (new-anchor! v b p)
    (let ([a (make-anchor-record (next-number!) v (buffers:anchor b p) #f)])
      (hashtable-set! anchors-by-id (anchor-record-id a) a)
      (hashtable-update! anchors-by-view v (lambda (as) (append as (list a))) '())
      (mark-dirty!)
      a))

  (define (forget-anchor! a)
    (unless (anchor-record-gone? a)
      (anchor-record-gone?-set! a #t)
      (hashtable-delete! anchors-by-id (anchor-record-id a))
      (let* ([v (anchor-record-view a)] [as (remq a (hashtable-ref anchors-by-view v '()))])
        (if (null? as) (hashtable-delete! anchors-by-view v) (hashtable-set! anchors-by-view v as)))
      (mark-dirty!)))

  (define (anchor-of-id id) (hashtable-ref anchors-by-id id #f))

  ;; Where an edit brought two item anchors together, the one that was
  ;; further on keeps its number: its text is what stayed there.
  (define (item-ids v b)
    (let ([version (buffers:version b)])
      (if (eqv? version (view-record-items-key v))
          (view-record-items v)
          (let ([t (make-eqv-hashtable)])
            (vector-for-each
              (lambda (e)
                (let* ([p (spot-position (item-anchor-spot e))] [other (hashtable-ref t p #f)])
                  (when (or (not other) (fx> (item-anchor-last e) (item-anchor-last other)))
                    (hashtable-set! t p e))))
              (hashtable-values (view-record-items v)))
            (let-values ([(ps es) (hashtable-entries t)])
              (vector-for-each (lambda (p e) (item-anchor-last-set! e p)) ps es))
            (view-record-items-set! v t)
            (view-record-items-key-set! v version)
            t))))

  (define (item-id ctx start)
    (let* ([v (context-view ctx)]
           [t (context-item-ids ctx)]
           [e (or (hashtable-ref t start #f)
                  (let ([e (make-item-anchor
                             (string-append "v" (number->string (view-record-id v)) "-"
                                            (number->string (view-record-next-item v)))
                             (buffers:anchor (view-record-buffer v) start) batches start)])
                    (view-record-next-item-set! v (fx+ (view-record-next-item v) 1))
                    (hashtable-set! t start e)
                    e))])
      (item-anchor-batch-set! e batches)
      (view-record-drawn-set! v batches)
      (item-anchor-name e)))

  ;; Anchors the view's last drawing did not draw are dropped. A batch
  ;; may draw no client, as while a reloaded page opens its stream, and
  ;; its items keep their numbers for the next drawing.
  (define (drop-undrawn-items! v)
    (let ([t (view-record-items v)] [drawn (view-record-drawn v)])
      (let-values ([(ps es) (hashtable-entries t)])
        (vector-for-each (lambda (p e) (when (fx< (item-anchor-batch e) drawn) (hashtable-delete! t p))) ps es))))

  ;; Batches are counted so that a view drawn for a client in this one is
  ;; told from one drawn before: a container may leave a view undrawn.
  (define batches 0)

  (define (anchor-drawn-for? a c)
    (let* ([v (anchor-record-view a)] [b (bound-buffer v)] [cs (hashtable-ref (view-record-clients v) c #f)])
      (and b cs (fx= (client-view-drawn-batch cs) batches) (client-view-from cs)
           (fx<= (spot-position (client-view-from cs)) (spot-position (anchor-record-spot a))
                 (spot-position (client-view-to cs))))))

  (define (make-new-scroller! on-rest)
    (let ([s (make-scroller-record (next-number!) #f 'nearest #f (make-eq-hashtable) on-rest #f)])
      (hashtable-set! scrollers (scroller-record-id s) s)
      s))

  (define (scroller-client s c)
    (let ([t (scroller-record-clients s)])
      (or (hashtable-ref t c #f)
          (let ([cs (make-scroller-state (next-number!) 0 #f #f)])
            (hashtable-set! t c cs)
            cs))))

  (define (set-scroller-place! s item align focus)
    (scroller-record-item-set! s item)
    (scroller-record-align-set! s align)
    (scroller-record-focus-set! s focus)
    (let-values ([(cs states) (hashtable-entries (scroller-record-clients s))])
      (vector-for-each (lambda (st) (scroller-state-number-set! st (next-number!))) states)))

  (define (forget-scroller! s)
    (scroller-record-dropped?-set! s #t)
    (hashtable-delete! scrollers (scroller-record-id s)))

  (define scroller-aligns '("start" "end" "center"))

  ;; Like a view's, a strip moves the other clients only once a hand
  ;; scroll on one comes to rest, and only from the placement that client
  ;; shows; that client is sent nothing, since its browser is already
  ;; there.
  (define (scroller-report c item)
    (define (field key) (let ([e (assoc key item)]) (if e (cdr e) 'null)))
    (define (token? x) (and (fixnum? x) (fx> x 0)))
    (let ([id (field "scroller")] [placement (field "placement")] [number (field "report")]
          [items (field "items")] [whole (field "whole")] [settled (field "settled")]
          [at (field "item")] [align (field "align")] [focus (field "focus")])
      (unless (and (fixnum? id) (fixnum? placement) (fixnum? number)
                   (vector? items) (for-all token? (vector->list items))
                   (vector? whole) (for-all token? (vector->list whole)) (boolean? settled)
                   (or (not settled) (and (token? at) (member align scroller-aligns) (token? focus))))
        (assertion-violation 'views "not a scroller report" item))
      (let ([s (hashtable-ref scrollers id #f)])
        (when s
          (let ([cs (scroller-client s c)])
            (scroller-state-reported-set! cs number)
            (scroller-state-in-view-set! cs (vector->list items))
            (scroller-state-whole-set! cs (vector->list whole))
            (when (and settled (fx= placement (scroller-state-number cs)))
              (let ([align (string->symbol align)])
                (unless (and (eqv? at (scroller-record-item s)) (eq? align (scroller-record-align s))
                             (eqv? focus (scroller-record-focus s)))
                  (let ([number (scroller-state-number cs)])
                    (set-scroller-place! s at align focus)
                    (scroller-state-number-set! cs number))
                  ((scroller-record-on-rest s) s c at align focus)))))))))

  (define (view-client v c)
    (let ([t (view-record-clients v)])
      (or (hashtable-ref t c #f)
          (let ([cs (make-client-view (and c (web:client-device c)))])
            (send-placement! cs (if (eq? (view-record-moved-last v) 'followed) (follow-place) (view-record-place v)))
            (hashtable-set! t c cs)
            cs))))

  (define (for-each-client-view proc v)
    (let-values ([(cs states) (hashtable-entries (view-record-clients v))])
      (vector-for-each proc cs states)))

  ;; BY is the client whose command placed the view: its report under the
  ;; placement makes what its browser shows the shared position.
  (define (place-all! v place by)
    (with-interrupts-disabled
      (view-record-place-set! v place)
      (view-record-placed-by-set! v by)
      (for-each-client-view (lambda (c cs) (send-placement! cs place)) v)
      (set! dirty? #t)))

  (define (align-view! v p align)
    (place-all! v (make-place align (make-spot (view-record-buffer v) p #f) 0.0 0.0 0.0) (web:current-client)))

  ;; Client C's browser was scrolled there by hand, so every other client
  ;; is placed there and C is sent nothing.
  (define (set-view-scroll! v c own)
    (with-interrupts-disabled
      (view-record-place-set! v own)
      (view-record-placed-by-set! v #f)
      (for-each-client-view (lambda (other cs) (unless (eq? other c) (send-placement! cs own))) v)
      (set! dirty? #t)))

  ;; What a browser measured of one buffer says nothing of another, but
  ;; each client keeps counting its placements, since its page may hold
  ;; the last one. The view's element keeps its size, so its size is kept
  ;; for body-size until the browser measures again: a display right after
  ;; a preview asks how big the view is.
  (define (forget-measured! v)
    (hashtable-clear! (view-record-devices v))
    (forget-items! v)
    (for-each-client-view
      (lambda (c cs)
        (when (client-view-facts cs) (client-view-sized-set! cs (client-view-facts cs)))
        (client-view-own-set! cs #f)
        (client-view-measured-set! cs #f)
        (client-view-facts-set! cs #f)
        (client-view-from-set! cs #f)
        (client-view-to-set! cs #f)
        (client-view-sizer-set! cs #f)
        (client-view-map-set! cs #f)
        (client-view-owed-set! cs #f))
      v))

  (define (forget-items! v)
    (view-record-items-set! v (make-eqv-hashtable))
    (view-record-items-key-set! v #f))

  ;; A device's maps go with its last client: a reload's new client is
  ;; drawn before the old one says goodbye, so a reload keeps them.
  (define (forget-client! c)
    (eq-hashtable-delete! presses c)
    (vector-for-each (lambda (s) (hashtable-delete! (scroller-record-clients s) c)) (hashtable-values scrollers))
    (for-each
      (lambda (v)
        (with-interrupts-disabled
          (hashtable-delete! (view-record-clients v) c)
          (when (eq? (view-record-placed-by v) c) (view-record-placed-by-set! v #f))
          (when (eq? (view-record-moved-by v) c) (view-record-moved-by-set! v #f))))
      views)
    (let ([device (web:client-device c)])
      (unless (exists (lambda (v)
                        (exists (lambda (cs) (equal? (client-view-device cs) device))
                                (vector->list (hashtable-values (view-record-clients v)))))
                      views)
        (for-each (lambda (v) (hashtable-delete! (view-record-devices v) device)) views))))

  (define (reset-view! v b)
    (let* ([n (if b (buffer-length b) 0)]
           [cursors (list (make-cursor-record v (point-spot b (if b (stop-within b 0 n 0) 0)) #f #f))])
      (with-interrupts-disabled
        (view-record-cursors-set! v cursors)
        (view-record-moved?-set! v #f)
        (view-record-moved-last-set! v 'followed)
        (view-record-folds-set! v '())
        (view-record-narrowing-set! v #f)
        (view-record-states-set! v '())
        (forget-measured! v)
        (place-all! v (make-place 'position (make-spot b 0 #f) 0.0 0.0 0.0) #f))))

  (define (make-new-view! id b name)
    (let ([v (make-view-record (or id next-id) name b (make-place 'position 0 0.0 0.0 0.0) '() #f #f)])
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
          (view-record-buffer-set! v b)
          (view-record-shown-count-set! v (fx+ (view-record-shown-count v) 1)))
        (forget-items! v)
        (for-each forget-anchor! (hashtable-ref anchors-by-view v '())))))

  (define (show-buffer! v b)
    (view-record-name-set! v (buffers:name b))
    (set-shown-buffer! v b)
    (reset-view! v b))

  (define (drop-view! v)
    (let ([b (view-record-buffer v)])
      (when (and b (buffers:live? b)) (note-left! v b)))
    (set! history-dirty? #t)
    (let ([all (remq v views)])
      (with-interrupts-disabled
        (set-shown-buffer! v #f)
        (hashtable-delete! by-id (view-record-id v))
        (set! views all)
        (view-record-dropped?-set! v #t)
        (set! dirty? #t)))
    (let-values ([(keys vs) (hashtable-entries copies)])
      (vector-for-each (lambda (k c) (when (eq? c v) (hashtable-delete! copies k))) keys vs)))

  ;; Read from saved data, a kept state's positions are numbers until a
  ;; buffer of the name is made, as a restored view's are.
  (define-record-type kept
    (sealed #t)
    (fields (mutable buffer) (mutable name) (mutable cursors) (mutable place) moved-last
            (mutable folds) (mutable narrowing) states))

  (define history-dirty? #f)

  (define movers (make-weak-eq-hashtable))
  (define left-points (make-weak-eq-hashtable))
  (define waiting-points (make-hashtable string-hash string=?))

  (define (internal-buffer? b) (buffers:internal-name? (buffers:name b)))

  (define (kept-of v b)
    (make-kept b (buffers:name b)
      (map (lambda (c) (cons (cursor-record-point c) (cursor-record-mark c))) (view-record-cursors v))
      (view-record-place v) (view-record-moved-last v) (view-record-folds v) (view-record-narrowing v)
      (view-record-states v)))

  (define (bind-kept! k b)
    (let* ([n (buffer-length b)] [spot (lambda (s after?) (make-spot b (fxmin n (spot-position s)) after?))])
      (with-interrupts-disabled
        (kept-buffer-set! k b)
        (kept-cursors-set! k (map (lambda (pm) (cons (point-spot b (fxmin n (spot-position (car pm))))
                                                     (and (cdr pm) (spot (cdr pm) #f))))
                                  (kept-cursors k)))
        (kept-place-set! k (let ([pl (kept-place k)]) (place-at pl (and (place-spot pl) (spot (place-spot pl) #f)))))
        (kept-folds-set! k (map (lambda (f) (cons (spot (car f) #t) (spot (cdr f) #f))) (kept-folds k)))
        (kept-narrowing-set! k (let ([r (kept-narrowing k)]) (and r (cons (spot (car r) #f) (spot (cdr r) #t))))))))

  (define (kept-now k)
    (let ([b (kept-buffer k)])
      (cond
        [b (and (buffers:live? b) b)]
        [(buffers:find (kept-name k)) => (lambda (b) (bind-kept! k b) b)]
        [else #f])))

  (define (kept-for v b)
    (find-first (lambda (k) (eq? (kept-now k) b)) (view-record-previous v)))

  (define (next-now v)
    (fold-right (lambda (x acc) (let ([b (if (string? x) (buffers:find x) x)]) (if (and b (buffers:live? b)) (cons b acc) acc)))
                '() (view-record-next v)))

  (define (previous-buffers-of v)
    (fold-right (lambda (k acc) (let ([b (kept-now k)]) (if b (cons b acc) acc))) '() (view-record-previous v)))

  (define (last-point-of b)
    (and (not (internal-buffer? b))
         (let ([v (eq-hashtable-ref movers b #f)])
           (cond
             [(and v (not (view-record-dropped? v)) (eq? (view-record-buffer v) b)) (point-of (car (view-record-cursors v)))]
             [(eq-hashtable-ref left-points b #f) => buffers:anchor-position]
             [(hashtable-ref waiting-points (buffers:name b) #f)
              => (lambda (p)
                   (let ([a (buffers:anchor b (fxmin p (buffer-length b)))])
                     (eq-hashtable-set! left-points b a)
                     (hashtable-delete! waiting-points (buffers:name b))
                     (buffers:anchor-position a)))]
             [else #f]))))

  (define (set-last-point-of! b p)
    (eq-hashtable-delete! movers b)
    (hashtable-delete! waiting-points (buffers:name b))
    (eq-hashtable-set! left-points b (buffers:anchor b p))
    (set! history-dirty? #t))

  (define (note-left! v b)
    (when (let ([m (eq-hashtable-ref movers b #f)])
            (or (not m) (eq? m v) (view-record-dropped? m) (not (eq? (view-record-buffer m) b))))
      (eq-hashtable-delete! movers b)
      (eq-hashtable-set! left-points b (buffers:anchor b (point-of (car (view-record-cursors v)))))
      (set! history-dirty? #t)))

  ;; A kept state's anchors stay with the history, so the view takes
  ;; fresh ones: a preview that ends puts the state back as it was.
  (define (show-kept! v b k)
    (view-record-name-set! v (buffers:name b))
    (set-shown-buffer! v b)
    (let*-values ([(n) (buffer-length b)]
                  [(lo hi) (let ([r (kept-narrowing k)])
                             (if r (values (spot-position (car r)) (spot-position (cdr r))) (values 0 n)))]
                  [(fresh) (lambda (s after?) (make-spot b (spot-position s) after?))])
      (with-interrupts-disabled
        (view-record-cursors-set! v
          (map (lambda (pm)
                 (make-cursor-record v (point-spot b (stop-within b lo hi (spot-position (car pm))))
                   (and (cdr pm) (fresh (cdr pm) #f)) #f))
               (kept-cursors k)))
        (view-record-folds-set! v (map (lambda (f) (cons (fresh (car f) #t) (fresh (cdr f) #f))) (kept-folds k)))
        (view-record-narrowing-set! v (let ([r (kept-narrowing k)]) (and r (cons (fresh (car r) #f) (fresh (cdr r) #t)))))
        (view-record-states-set! v (kept-states k))
        (view-record-moved?-set! v (eq? (kept-moved-last k) 'followed))
        (view-record-moved-last-set! v (kept-moved-last k)))
      (forget-measured! v)
      (let ([pl (kept-place k)])
        (place-all! v (place-at pl (and (place-spot pl) (fresh (place-spot pl) #f))) #f))))

  (define (show-at-point! v b p)
    (show-buffer! v b)
    (let ([n (buffer-length b)])
      (with-interrupts-disabled
        (cursor-record-point-set! (car (view-record-cursors v)) (point-spot b (stop-within b 0 n (fxmin p n))))
        (view-record-moved?-set! v #t))))

  (define (leave! v)
    (let ([b (view-record-buffer v)])
      (when (and b (buffers:live? b))
        (note-left! v b)
        (unless (internal-buffer? b)
          (view-record-previous-set! v
            (cons (kept-of v b) (remp (lambda (k) (eq? (kept-now k) b)) (view-record-previous v))))))))

  (define (enter! v b)
    (let ([k (kept-for v b)] [p (last-point-of b)])
      (when k (view-record-previous-set! v (remq k (view-record-previous v))))
      (cond
        [k (show-kept! v b k)]
        [p (show-at-point! v b p)]
        [else (show-buffer! v b)])
      (eq-hashtable-set! movers b v)
      (set! history-dirty? #t)
      (mark-dirty!)))

  (define (switch-buffer! v b)
    (unless (eq? (view-record-buffer v) b)
      (leave! v)
      (view-record-next-set! v '())
      (enter! v b)))

  (define (skipped? v b reason) ((skipped-buffer-predicate) v b reason))

  (define (previous-buffer-in! v)
    (let* ([old (view-record-buffer v)] [next (next-now v)]
           [ok? (lambda (b) (and b (not (eq? b old)) (not (memq b next)) (not (skipped? v b 'previous))))]
           [b (or (exists (lambda (k) (let ([b (kept-now k)]) (and (ok? b) b))) (view-record-previous v))
                  (find-first (lambda (b) (and (ok? b) (not (internal-buffer? b)))) (reverse (buffers:all)))
                  (find-first (lambda (b) (and (not (eq? b old)) (kept-for v b) (not (skipped? v b 'previous))))
                              (reverse next)))])
      (when b
        (leave! v)
        (enter! v b)
        (view-record-next-set! v (if old (cons old (remq old next)) next)))
      b))

  (define (next-buffer-in! v)
    (let* ([old (view-record-buffer v)] [next (next-now v)]
           [ok? (lambda (b) (and b (not (eq? b old)) (not (skipped? v b 'next))))]
           [b (or (find-first (lambda (b) (and (ok? b) (kept-for v b))) next)
                  (find-first (lambda (b) (and (ok? b) (not (internal-buffer? b)) (not (kept-for v b)))) (buffers:all))
                  (exists (lambda (k) (let ([b (kept-now k)]) (and (ok? b) b))) (reverse (view-record-previous v))))])
      (when b
        (leave! v)
        (enter! v b)
        (view-record-next-set! v (remq b next)))
      b))

  (define (replace-buffer-in! v reason)
    (let* ([old (view-record-buffer v)]
           [ok? (lambda (b) (and b (not (eq? b old)) (not (skipped? v b reason))))]
           [b (or (exists (lambda (k) (let ([b (kept-now k)]) (and (ok? b) b))) (view-record-previous v))
                  (find-first (lambda (b) (and (ok? b) (not (internal-buffer? b)))) (buffers:all)))])
      (when b
        (when (and old (buffers:live? old)) (note-left! v old))
        (forget-in-history! v old)
        (enter! v b))
      b))

  (define (forget-in-history! v b)
    (view-record-previous-set! v (remp (lambda (k) (or (eq? (kept-buffer k) b) (and (not (kept-buffer k)) b (string=? (kept-name k) (buffers:name b))))) (view-record-previous v)))
    (view-record-next-set! v (remp (lambda (x) (if (string? x) (and b (string=? x (buffers:name b))) (eq? x b))) (view-record-next v)))
    (set! history-dirty? #t))

  ;; A preview changes no buffer's last point, so it keeps the entries it
  ;; touches and puts them back when it ends.
  (define (keep-last-point! before b)
    (when (and b (not (assq b (vector-ref before 4))))
      (vector-set! before 4
        (cons (list b (eq-hashtable-ref movers b #f) (eq-hashtable-ref left-points b #f)) (vector-ref before 4)))))

  (define (put-back-last-points! before)
    (for-each
      (lambda (e)
        (let ([b (car e)] [mover (cadr e)] [left (caddr e)])
          (if mover (eq-hashtable-set! movers b mover) (eq-hashtable-delete! movers b))
          (if left (eq-hashtable-set! left-points b left) (eq-hashtable-delete! left-points b))))
      (vector-ref before 4)))

  (define (preview-in! v b)
    (unless (view-record-preview v)
      (let ([old (view-record-buffer v)])
        (view-record-preview-set! v
          (vector old (and old (buffers:live? old) (kept-of v old)) (view-record-previous v) (view-record-next v) '()))))
    (unless (eq? (view-record-buffer v) b)
      (let ([before (view-record-preview v)])
        (keep-last-point! before (view-record-buffer v))
        (keep-last-point! before b))
      (leave! v)
      (enter! v b)))

  (define (previewing-in? v) (and (view-record-preview v) #t))

  (define (end-preview-in! v)
    (let ([before (view-record-preview v)])
      (when before
        (view-record-preview-set! v #f)
        (let ([old (vector-ref before 0)] [k (vector-ref before 1)] [b (view-record-buffer v)])
          (when (and k (buffers:live? old) (not (eq? b old)))
            (show-kept! v old k)))
        (put-back-last-points! before)
        (view-record-previous-set! v (vector-ref before 2))
        (view-record-next-set! v (vector-ref before 3))
        (set! history-dirty? #t)
        (mark-dirty!))))

  (define (place-at pl spot)
    (make-place (place-kind pl) spot (place-offset pl) (place-height pl) (place-left pl)))

  ;; A view whose buffer is gone keeps its positions as numbers, so a
  ;; buffer made again under the name shows them.
  (define (unbind! v)
    (define (number s) (and s (spot-position s)))
    (let* ([cs (view-record-cursors v)]
           [points (map (lambda (c) (number (cursor-record-point c))) cs)]
           [marks (map (lambda (c) (number (cursor-record-mark c))) cs)]
           [pl (let ([pl (view-record-place v)]) (place-at pl (number (place-spot pl))))]
           [folds (map (lambda (f) (cons (number (car f)) (number (cdr f)))) (view-record-folds v))]
           [narrowing (let ([r (view-record-narrowing v)]) (and r (cons (number (car r)) (number (cdr r)))))])
      (commit-positions! v #f cs points marks pl folds narrowing)))

  (define (bind! v b)
    (let* ([n (buffer-length b)]
           [spot (lambda (s after?) (make-spot b (fxmin n (spot-position s)) after?))]
           [narrowing (let ([r (view-record-narrowing v)]) (and r (cons (spot (car r) #f) (spot (cdr r) #t))))]
           [lo (if narrowing (spot-position (car narrowing)) 0)]
           [hi (if narrowing (spot-position (cdr narrowing)) n)]
           [cs (view-record-cursors v)]
           [points (map (lambda (c) (point-spot b (stop-within b lo hi (spot-position (cursor-record-point c))))) cs)]
           [marks (map (lambda (c) (let ([m (cursor-record-mark c)]) (and m (spot m #f)))) cs)]
           [pl (let ([pl (view-record-place v)]) (place-at pl (and (place-spot pl) (spot (place-spot pl) #f))))]
           [folds (map (lambda (f) (cons (spot (car f) #t) (spot (cdr f) #f))) (view-record-folds v))])
      (commit-positions! v b cs points marks pl folds narrowing)))

  ;; A quit leaves a view showing its old buffer or its new one, never
  ;; positions of both.
  (define (commit-positions! v b cs points marks pl folds narrowing)
    (with-interrupts-disabled
      (for-each (lambda (c p m) (cursor-record-point-set! c p) (cursor-record-mark-set! c m)) cs points marks)
      (view-record-folds-set! v folds)
      (view-record-narrowing-set! v narrowing)
      (view-record-states-set! v '())
      (set-shown-buffer! v b)
      (forget-measured! v)
      (place-all! v pl #f)))

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

  (define (whole-node? n)
    (or (document:atom? n)
        (let ([k (buffers:kind (document:node-kind n))]) (and k (buffers:kind-whole? k)))))

  (define (child-of doc n m)
    (let ([ns (document:node-start n)])
      (let loop ([m m])
        (let ([parent (document:enclosing doc (document:node-start m))])
          (if (fx= (document:node-start parent) ns) m (loop parent))))))

  ;; Only a newline in N's own text ends one of its runs, so a newline
  ;; inside a child sends the search past that child.
  (define (run-start doc n p lo)
    (let ([ns (document:node-start n)] [cs (fx+ (document:node-start n) 1)])
      (let loop ([p p])
        (let* ([line (document:line doc p)] [nl (if (fx= line 1) -1 (fx- (document:line-start doc line) 1))])
          (cond
            [(fx< nl cs) (fxmax lo cs)]
            [(fx= (document:node-start (document:enclosing doc nl)) ns) (fxmax lo (fx+ nl 1))]
            [else (loop (document:node-start (child-of doc n (document:enclosing doc nl))))])))))

  (define (run-end doc n p hi)
    (let ([ns (document:node-start n)] [ce (fx- (document:node-end n) 1)]
          [lines (document:line doc (document:length doc))])
      (let loop ([p p])
        (let* ([line (document:line doc p)] [nl (if (fx= line lines) ce (fx- (document:line-start doc (fx+ line 1)) 1))])
          (cond
            [(fx>= nl ce) (fxmin hi ce)]
            [(fx= (document:node-start (document:enclosing doc nl)) ns) (fxmin hi (fx+ nl 1))]
            [else (loop (document:node-end (child-of doc n (document:enclosing doc nl))))])))))

  (define (holders doc p)
    (let ([inner (let loop ([n (document:enclosing doc p)] [acc '()])
                   (if n (loop (document:enclosing doc (document:node-start n)) (cons n acc)) acc))]
          [t (document:token doc p)])
      (if (document:node? t) (append inner (list t)) inner)))

  (define (token-near doc lo hi p)
    (let forward ([q (fxmax lo (fxmin p (fx- hi 1)))])
      (cond
        [(fx>= q hi)
         (let back ([q (fx- hi 1)])
           (if (and (fx> q lo) (eq? (document:token doc q) 'close)) (back (fx- q 1)) q))]
        [(eq? (document:token doc q) 'close) (forward (fx+ q 1))]
        [else q])))

  ;; Items must be what block-html draws: a line of block content,
  ;; inline nodes and all, or a node standing alone that is whole; any
  ;; other node standing alone opens into its children's items.
  (define (item-at doc lo hi p)
    (if (fx>= lo hi)
        (values lo hi)
        (let* ([p (token-near doc lo hi p)] [at-node? (document:node? (document:token doc p))])
          (let loop ([n #f] [chain (holders doc p)])
            (let ([n (or n (car chain))] [rest (if n chain (cdr chain))])
              (if (null? rest)
                  (values (run-start doc n p lo) (run-end doc n p hi))
                  (let ([x (car rest)])
                    (cond
                      [(document:in-line? x)
                       (let ([s (document:node-start x)]) (values (run-start doc n s lo) (run-end doc n s hi)))]
                      [(whole-node? x) (values (fxmax lo (document:node-start x)) (fxmin hi (document:node-end x)))]
                      [(or (pair? (cdr rest)) (not at-node?)) (loop x (cdr rest))]
                      [(fx< (fx+ (document:node-start x) 1) (fx- (document:node-end x) 1))
                       (item-at doc lo hi (fx+ (document:node-start x) 1))]
                      [else (values (fxmax lo (document:node-start x)) (fxmin hi (document:node-end x)))]))))))))

  (define (item-bounds v doc)
    (let-values ([(lo hi) (bounds-of v)])
      (values (fxmax lo 1) (fxmin hi (fx- (document:length doc) 1)))))

  ;; A fold hides the newlines it holds, so the drawing joins the text
  ;; before it and after it into one line: an item boundary B goes when
  ;; the token before it, B - 1, is folded.
  (define (view-item v doc p)
    (let-values ([(lo hi) (item-bounds v doc)])
      (let ([folds (live-folds v)])
        (if (null? folds)
            (item-at doc lo hi p)
            (let ([folds (map (lambda (f) (cons (spot-position (car f)) (spot-position (cdr f)))) folds)])
              (define (folding b) (find-first (lambda (f) (fx< (car f) b (fx+ (cdr f) 1))) folds))
              (let-values ([(s e) (item-at doc lo hi p)])
                (values
                  (let back ([s s])
                    (let ([f (and (fx> s lo) (folding s))])
                      (if f
                          (let-values ([(a z) (item-at doc lo hi (car f))]) (if (fx< a s) (back a) s))
                          s)))
                  (let forward ([e e])
                    (let ([f (and (fx< e hi) (folding e))])
                      (if f
                          (let-values ([(a z) (item-at doc lo hi (cdr f))]) (if (fx> z e) (forward z) e))
                          e))))))))))

  (define (item-start-at v doc p) (let-values ([(s e) (view-item v doc p)]) s))

  (define (items-around v doc p n)
    (let-values ([(lo hi) (item-bounds v doc)] [(s e) (view-item v doc p)])
      (values (let back ([s s] [k n])
                (if (or (fx= k 0) (fx<= s lo))
                    s
                    (let-values ([(a z) (view-item v doc (fx- s 1))])
                      (back (if (fx< a s) a (fx- s 1)) (fx- k 1)))))
              (let forward ([e e] [k n])
                (if (or (fx= k 0) (fx>= e hi))
                    e
                    (let-values ([(a z) (view-item v doc e)])
                      (forward (if (fx> z e) z (fx+ e 1)) (fx- k 1))))))))

  ;; Atoms count as characters too, so the text's characters are the
  ;; characters less the atoms standing alone; an atom drawn in a line
  ;; takes room as a character does. Each other node is an opening and a
  ;; closing.
  (define (counter doc)
    (define (between a z unit) (fx- (document:offset doc z unit) (document:offset doc a unit)))
    (let ([chars (document:unit characters)] [atoms (document:unit atoms)] [in-line (document:unit in-line-atoms)])
      (lambda (a z)
        (let ([n (between a z chars)] [standing (fx- (between a z atoms) (between a z in-line))])
          (values (fx- (document:line doc z) (document:line doc a)) (fx- n standing) standing
                  (fxquotient (fx- (fx- z a) n) 2))))))

  (define (device-view! v device)
    (let ([t (view-record-devices v)])
      (or (hashtable-ref t device #f)
          (let ([d (make-device-view '() (wrap-lines) #f #f)])
            (hashtable-set! t device d)
            d))))

  (define (client-map v doc cs)
    (let* ([device (client-view-device cs)] [d (and device (hashtable-ref (view-record-devices v) device #f))])
      (and d (eq? (device-view-wrap? d) (wrap-lines))
           (let* ([f (client-view-facts cs)] [e (assv (if f (facts-width f) (device-view-width d)) (device-view-maps d))])
             (and e (fx= (height-map-length (cdr e)) (document:length doc)) (cdr e))))))

  (define (client-height v cs)
    (let ([f (client-view-facts cs)])
      (if f
          (facts-height f)
          (let ([d (and (client-view-device cs) (hashtable-ref (view-record-devices v) (client-view-device cs) #f))])
            (or (and d (device-view-height d)) 0)))))

  ;; The browser of a client that reported under the newest placement, or
  ;; under a newest one that only follows point, shows what it reported.
  (define (current-own cs)
    (let ([own (client-view-own cs)])
      (and own
           (or (eqv? (client-view-measured cs) (client-view-number cs))
               (eq? (place-kind (client-view-placement cs)) 'follow))
           own)))

  ;; Until the client reports under a placement that follows point, its
  ;; own position is from before point moved, and a run drawn around it
  ;; must still hold point for the browser to show it. Deciding by the run
  ;; last drawn instead would alternate the run between point and own.
  (define (run-top v doc m cs height wanted)
    (let ([pl (client-view-placement cs)] [own (current-own cs)])
      (define (item-px p) (height-map-px m (item-start-at v doc p)))
      (define (own-px own) (fl+ (item-px (spot-position (place-spot own))) (place-offset own)))
      (define (point-near? top)
        (let ([p (height-map-px m (point-of (car (view-record-cursors v))))])
          (and (fl>= p (fl- top wanted)) (fl<= p (fl+ top height wanted)))))
      (cond
        [(and own (or (not (eq? (place-kind pl) 'follow)) (eqv? (client-view-measured cs) (client-view-number cs))
                      (point-near? (own-px own))))
         (own-px own)]
        [else
         (case (place-kind pl)
           [(position) (own-px pl)]
           [(top) (item-px (spot-position (place-spot pl)))]
           [(center) (fl- (height-map-px m (spot-position (place-spot pl))) (fl/ height 2.0))]
           [(bottom) (fl- (height-map-px m (spot-position (place-spot pl))) height)]
           [else (fl- (height-map-px m (point-of (car (view-record-cursors v)))) (fl/ height 2.0))])])))

  ;; Firefox takes a box taller than 17,895,697 px as 0 px tall and
  ;; Chromium clamps one at 33,554,428 px, so spacers and the sizer are
  ;; scaled to stay under 2^24 px; drawn items keep their size.
  (define most-scroll-px 16777216.0)

  (define (set-edges! v cs ws we)
    (let ([b (view-record-buffer v)])
      (define (edge s p) (if s (move-spot s b p #f) (make-spot b p #f)))
      (client-view-from-set! cs (edge (client-view-from cs) ws))
      (client-view-to-set! cs (edge (client-view-to cs) we))))

  (define (cold-center v cs)
    (let ([pl (client-view-placement cs)] [own (current-own cs)])
      (cond
        [own (spot-position (place-spot own))]
        [(place-spot pl) (spot-position (place-spot pl))]
        [else (point-of (car (view-record-cursors v)))])))

  ;; An edge gains items when fewer than the wanted px lie beyond it, and
  ;; loses only those wholly past twice that, so a scroll by a line does
  ;; not redraw the run; where less than half the wanted px remain to an
  ;; end, every item to it is drawn.
  (define (client-run! v doc cs)
    (let-values ([(lo hi) (item-bounds v doc)])
      (let ([m (and (client-view-device cs) (client-map v doc cs))])
        (client-view-map-set! cs m)
        (if (not m)
            (let-values ([(ws we) (items-around v doc (cold-center v cs) initial-drawn-items)])
              (set-edges! v cs ws we)
              (client-view-sizer-set! cs #f)
              (values ws we #f #f))
            (let* ([height (fixnum->flonum (client-height v cs))]
                   [wanted (fl* height (inexact (drawn-screens)))]
                   [top (run-top v doc m cs height wanted)]
                   [lo-px (height-map-px m lo)] [hi-px (height-map-px m hi)]
                   [from (client-view-from cs)] [to (client-view-to cs)]
                   [ws0 (and from (spot-position from))] [we0 (and to (spot-position to))]
                   [fresh? (or (not ws0) (fx< ws0 lo) (fx> we0 hi) (fx>= ws0 we0)
                               (fl< top (height-map-px m ws0)) (fl> (fl+ top height) (height-map-px m we0)))])
              (define (start-at px)
                (if (fl<= (fl- px lo-px) (fl/ wanted 2.0)) lo (item-start-at v doc (height-map-position m px))))
              (define (end-at px)
                (if (fl<= (fl- hi-px px) (fl/ wanted 2.0))
                    hi
                    (let-values ([(s e) (view-item v doc (height-map-position m px))]) e)))
              (let* ([above (if fresh? 0.0 (fl- top (height-map-px m ws0)))]
                     [below (if fresh? 0.0 (fl- (height-map-px m we0) (fl+ top height)))]
                     [ws (cond
                           [(or fresh? (and (fl< above wanted) (fx> ws0 lo))) (start-at (fl- top wanted))]
                           [(fl> above (fl* 2.0 wanted)) (start-at (fl- top (fl* 1.5 wanted)))]
                           [else ws0])]
                     [we (cond
                           [(or fresh? (and (fl< below wanted) (fx< we0 hi))) (end-at (fl+ top height wanted))]
                           [(fl> below (fl* 2.0 wanted)) (end-at (fl+ top height (fl* 1.5 wanted)))]
                           [else we0])]
                     [total (fl- hi-px lo-px)]
                     [scale (if (fl> total most-scroll-px) (fl/ most-scroll-px total) 1.0)]
                     [sizer (let ([old (client-view-sizer cs)] [drawn (fl- (height-map-px m we) lo-px)])
                              (if (or (not old) (fl> drawn old)) total old))])
                (set-edges! v cs ws we)
                (client-view-sizer-set! cs sizer)
                (client-view-scale-set! cs scale)
                (values ws we (fl* scale (fl- (height-map-px m ws) lo-px)) (fl* scale sizer))))))))

  ;; What a browser rounds an edge to.
  (define edge-tolerance 0.5)

  (define next-screen-context-lines 2)

  (define (point-to! v b doc target after?)
    (let-values ([(lo hi) (bounds-of v)])
      (let* ([c (car (view-record-cursors v))]
             [chars (document:unit characters)]
             [offset (lambda (p) (document:offset doc p chars))]
             [p (point-of c)]
             [column (or (cursor-record-goal c) (fx- (offset p) (offset (document:line-start doc (document:line doc p)))))]
             [line (document:line doc target)]
             [ls (offset (document:line-start doc line))]
             [le (if (fx< line (document:line doc (document:length doc)))
                     (fx- (offset (document:line-start doc (fx+ line 1))) 1)
                     (offset (document:length doc)))]
             [t (offset target)]
             [want (fxmin le (fx+ ls column))])
        (set-cursor-spots! c (stop-within b lo hi (document:position doc (if after? (fxmax t want) (fxmin t want)) chars))
                           (mark-of c)))))

  (define (move-point-into-view! v b cs)
    (let ([f (client-view-facts cs)])
      (when (and f (facts-start f) (facts-end f))
        (let ([doc (buffers:document b)] [p (point-of (car (view-record-cursors v)))]
              [start (spot-position (facts-start f))] [end (spot-position (facts-end f))])
          (cond
            [(fx< p start) (point-to! v b doc start #t)]
            [(fx> p end) (point-to! v b doc end #f)])))))

  ;; Each client keeps point in view in its own geometry, so following
  ;; point is a placement every client applies; the report of the client
  ;; whose command moved point makes what it shows the shared position.
  (define (follow-point! v)
    (let ([pl (follow-place)])
      (with-interrupts-disabled
        (view-record-moved?-set! v #f)
        (view-record-moved-last-set! v 'followed)
        (view-record-placed-by-set! v (or (view-record-moved-by v) 'anyone))
        (for-each-client-view (lambda (c cs) (send-placement! cs pl)) v)
        (set! dirty? #t))))

  (define (scroll-to-place! v p align)
    (align-view! v p align)
    (with-interrupts-disabled
      (view-record-moved?-set! v #f)
      (view-record-moved-last-set! v 'scrolled)))

  (define (same-position? a b)
    (and (eq? (place-kind a) 'position) (eq? (place-kind b) 'position)
         (eqv? (spot-position (place-spot a)) (spot-position (place-spot b)))
         (fl< (flabs (fl- (place-offset a) (place-offset b))) edge-tolerance)
         (fl< (flabs (fl- (place-left a) (place-left b))) edge-tolerance)))

  (define-record-type measured
    (sealed #t)
    (fields placement version top offset item-height left start end spacer distance items
            line-height char-width width height settled? hand? at-end? below))

  (define (mark-field mark key) (let ([e (assoc key mark)]) (and e (cdr e))))

  (define (mark-resolver b version)
    (let* ([edits (buffers:edits-since b version)]
           [doc (buffers:document b)]
           [size (and edits (fold-left (lambda (n e) (fx- n (edit-delta e))) (document:length doc) edits))]
           [then #f])
      (lambda (mark)
        (and edits mark
             (let ([token (mark-field mark "token")] [at (mark-field mark "at")] [line (mark-field mark "line")]
                   [count (or (mark-field mark "count") 0)])
               (let ([p (cond
                          [token token]
                          [at (fx+ at count)]
                          [line
                           (unless then (set! then (if (null? edits) doc (document-then doc edits))))
                           (and (fx<= line (document:line then (document:length then)))
                                (fx+ (document:line-start then line) count))]
                          [else #f])])
                 (and p (fx< p size) (follow p edits))))))))

  (define (whole-at? doc p)
    (let ([t (document:token doc p)]) (and (document:node? t) (whole-node? t))))

  ;; Each item's advance is the px from its top to the next item's, so the
  ;; margins and container markup between them count; the last's is its
  ;; height.
  ;; Most of a report's items were measured as they are by the report
  ;; before, and are left as they are.
  (define (measure-items! v doc m starts advances)
    (define (measure! s end px)
      (let-values ([(from to old measured?) (height-map-stretch m s)])
        (unless (and measured? (fx= from s) (fx= to end) (fl< (flabs (fl- old px)) 0.01))
          (height-map-measure! m s end px (whole-at? doc s)))))
    (let loop ([starts starts] [advances advances])
      (when (pair? starts)
        (let ([s (car starts)] [next (and (pair? (cdr starts)) (cadr starts))])
          (cond
            [(not s)]
            [next (when (fx< s next) (measure! s next (car advances)))]
            [(null? (cdr starts))
             (let-values ([(a z) (view-item v doc s)])
               (measure! s (fxmin (document:length doc) (fxmax z (fx+ s 1))) (car advances)))])
          (loop (cdr starts) (cdr advances))))))

  ;; A device keeps the maps of the widths its clients last reported, so
  ;; dragging a window's edge leaves no map per width passed.
  (define (report-map! v doc cs r)
    (let* ([device (client-view-device cs)] [d (device-view! v device)] [wrap? (wrap-lines)] [width (measured-width r)]
           [widths (fold-left (lambda (acc other)
                                (let ([f (client-view-facts other)])
                                  (if (and f (not (eq? other cs)) (equal? (client-view-device other) device))
                                      (cons (facts-width f) acc)
                                      acc)))
                              (list width) (vector->list (hashtable-values (view-record-clients v))))])
      (if (eq? (device-view-wrap? d) wrap?)
          (device-view-maps-set! d (filter (lambda (e) (memv (car e) widths)) (device-view-maps d)))
          (begin
            (device-view-maps-set! d '())
            (device-view-wrap?-set! d wrap?)))
      (device-view-width-set! d width)
      (device-view-height-set! d (measured-height r))
      ;; A character is taken to be at least a px wide, so a report's tiny
      ;; character width cannot make a row's count overflow a fixnum.
      (let ([row-chars (and wrap? (fxmax 1 (flonum->fixnum (flfloor (fl/ (fixnum->flonum width) (flmax 1.0 (measured-char-width r)))))))]
            [e (assv width (device-view-maps d))])
        (if (and e (fx= (height-map-length (cdr e)) (document:length doc)))
            (begin (height-map-set-metrics! (cdr e) (measured-line-height r) row-chars) (cdr e))
            (let ([m (make-height-map (document:length doc) (measured-line-height r) row-chars (counter doc))])
              (device-view-maps-set! d (cons (cons width m) (remp (lambda (e) (fx= (car e) width)) (device-view-maps d))))
              m)))))

  ;; A report from a spacer counts from the drawn item next to it, never
  ;; from the buffer's start, so no estimate of everything above adds up.
  (define (own-from-report v b doc m cs r top starts)
    (define (position-at px)
      (let-values ([(a z) (view-item v doc (height-map-position m px))])
        (make-place 'position (make-spot b a #f) (flmax 0.0 (fl- px (height-map-px m a)))
                    (fl- (height-map-px m z) (height-map-px m a)) (measured-left r))))
    (let ([known (filter values starts)] [distance (fl/ (measured-distance r) (client-view-scale cs))])
      (cond
        [top
         (let-values ([(a z) (view-item v doc top)])
           (make-place 'position (make-spot b a #f) (measured-offset r) (measured-item-height r) (measured-left r)))]
        [(null? known) #f]
        [(eq? (measured-spacer r) 'above) (position-at (fl- (height-map-px m (car known)) distance))]
        [(eq? (measured-spacer r) 'below)
         (let ([last (list-ref known (fx- (length known) 1))])
           (let-values ([(a z) (view-item v doc last)])
             (position-at (fl+ (height-map-px m z) distance))))]
        [else #f])))

  ;; Only a report at rest from a client scrolled by hand moves the shared
  ;; position, so a fling moves the other clients once, where it ends. The
  ;; first report under a placement only confirms it, so clients of
  ;; different sizes, which apply one placement a little differently,
  ;; never place each other back and forth; but the browser of the client
  ;; whose command placed the view shows where it went, and that becomes
  ;; the shared position.
  (define (adopt-report! v b c cs r)
    (let* ([doc (buffers:document b)]
           [resolve (mark-resolver b (measured-version r))]
           [m (report-map! v doc cs r)]
           [starts (map (lambda (mark) (resolve mark)) (map car (measured-items r)))])
      (measure-items! v doc m starts (map cdr (measured-items r)))
      (let* ([old-facts (client-view-facts cs)]
             [old-own (client-view-own cs)]
             [own (own-from-report v b doc m cs r (let ([top (measured-top r)]) (and top (resolve top))) starts)]
             [placed? (not (eqv? (client-view-measured cs) (measured-placement r)))]
             [resized? (and old-facts (not (and (fx= (facts-width old-facts) (measured-width r))
                                                (fx= (facts-height old-facts) (measured-height r)))))]
             [by-hand? (and own (measured-hand? r) (not placed?) (not resized?))]
             [spot (lambda (mark) (let ([p (resolve mark)]) (and p (make-spot b p #f))))])
        (with-interrupts-disabled
          (client-view-facts-set! cs (make-facts (measured-width r) (measured-height r) (measured-line-height r) (measured-char-width r)
                                                 (spot (measured-start r)) (spot (measured-end r)) (measured-at-end? r) (measured-below r)))
          (client-view-measured-set! cs (measured-placement r))
          (client-view-map-set! cs m)
          (when own (client-view-own-set! cs own))
          (when (measured-settled? r) (client-view-sizer-set! cs #f)))
        (cond
          [(and placed? own (memq (view-record-placed-by v) (list c 'anyone)))
           (with-interrupts-disabled
             (unless (eq? (place-kind (client-view-placement cs)) 'position)
               (view-record-place-set! v own)
               (set! dirty? #t))
             (view-record-placed-by-set! v #f))
           'commanded]
          [placed? 'placed]
          [(and by-hand? (measured-settled? r) (not (same-position? own (view-record-place v))))
           (set-view-scroll! v c own)
           'moved]
          [(and by-hand? (not (and old-own (same-position? own old-own)))) 'moved]
          [else 'still]))))

  (define (after-report! v b cs how)
    (when (eq? how 'moved)
      (view-record-moved-last-set! v 'scrolled))
    (let ([owed (client-view-owed cs)])
      (cond
        [owed (client-view-owed-set! cs #f) (when-measured! cs owed)]
        [(and (eq? how 'moved) (hand-scroll-moves-point)) (move-point-into-view! v b cs)]
        [(and (eq? how 'commanded) (eq? (view-record-moved-last v) 'scrolled)) (move-point-into-view! v b cs)])))

  ;; A scroll command reads what the client's browser shows, so it waits
  ;; for the browser to measure the newest placement; a client owes at
  ;; most one, the latest.
  (define (when-measured! cs scroll)
    (if (and (client-view-facts cs) (client-view-map cs) (current-own cs))
        (scroll)
        (client-view-owed-set! cs scroll)))

  (define (scroll-by! v b c cs forward?)
    (let* ([doc (buffers:document b)] [f (client-view-facts cs)] [own (current-own cs)] [m (client-view-map cs)]
           [line-height (facts-line-height f)] [s (spot-position (place-spot own))])
      (let-values ([(lo hi) (item-bounds v doc)])
        (if forward?
            (when (and (facts-at-end? f) (fl<= (facts-below f) edge-tolerance))
              (error 'views:scroll-up "end of buffer"))
            (when (and (fx<= s lo) (fl< (place-offset own) edge-tolerance))
              (error 'views:scroll-down "beginning of buffer")))
        (let* ([step (flmax line-height (fl- (fixnum->flonum (facts-height f))
                                              (fl* line-height (fixnum->flonum next-screen-context-lines))))]
               [top (fl+ (height-map-px m (item-start-at v doc s)) (place-offset own))]
               [px (flmax (height-map-px m lo) (if forward? (fl+ top step) (fl- top step)))])
          (let-values ([(a z) (view-item v doc (height-map-position m px))])
            (place-all! v (make-place 'position (make-spot b a #f) (flmax 0.0 (fl- px (height-map-px m a)))
                                      (fl- (height-map-px m z) (height-map-px m a)) (place-left own))
                        c)
            (with-interrupts-disabled
              (view-record-moved?-set! v #f)
              (view-record-moved-last-set! v 'scrolled)))))))

  (define recentered 'bottom)

  (define (recenter! v b again?)
    (let ([align (if again? (case recentered [(center) 'top] [(top) 'bottom] [else 'center]) 'center)])
      (align-view! v (point-of (car (view-record-cursors v))) align)
      (set! recentered align)
      (with-interrupts-disabled
        (view-record-moved?-set! v #f)
        (view-record-moved-last-set! v 'followed))))

  (define current-context (make-thread-parameter #f))
  (define in-line? (make-thread-parameter #f))
  (define drawing (make-thread-parameter '()))

  (define (drawing? v) (memq v (drawing)))

  (define-record-type (context new-context context?)
    (sealed #t)
    (fields view client doc lo hi ws we root cursors anchors regions spans longest folds (mutable shown) item-ids marks? ends
            marker above sizer))

  (define-record-type span-entry
    (sealed #t)
    (fields start end rank open close before after replace face))

  (define-record-type span-style
    (sealed #t)
    (fields open close before after replace))

  (define-record-type insertion
    (sealed #t)
    (fields at order html span))

  (define-record-type content-piece
    (sealed #t)
    (fields stack from to html))

  (define (fold-ranges v)
    (list-sort (lambda (a b) (fx< (car a) (car b)))
               (map (lambda (f) (cons (spot-position (car f)) (spot-position (cdr f)))) (live-folds v))))

  (define (by-position marks) (list-sort (lambda (a b) (fx< (car a) (car b))) marks))

  (define (cursor-points v)
    (if (cursor-visible)
        (by-position
          (let loop ([cs (view-record-cursors v)] [primary? #t])
            (if (null? cs) '() (cons (cons (point-of (car cs)) primary?) (loop (cdr cs) #f)))))
        '()))

  (define (anchor-points v)
    (by-position
      (map (lambda (a) (cons (spot-position (anchor-record-spot a)) (anchor-html a)))
           (hashtable-ref anchors-by-view v '()))))

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

  ;; Attribute names come from users' tables, so the element is written
  ;; here rather than by haml, which takes names only as written in code.
  (define (put-element p value classes malformed! click)
    (let loop ([value (if (list? value) value '())] [classes (reverse classes)] [others (if click (list (cons "data-click" click)) '())])
      (cond
        [(null? value)
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
         (put-char p #\>)]
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

  ;; A list of faces is drawn as nested elements, the first innermost, so
  ;; its rules win, as Emacs gives a list's earlier faces priority.
  (define (span-open value classes malformed! click)
    (define (element-start value click)
      (call-with-string-output-port (lambda (p) (put-element p value classes malformed! click))))
    (let* ([faces (value-ref value 'face)]
           [bare (element-start '() #f)]
           [elements
            (filter (lambda (open) (not (string=? open bare)))
              (if (and (pair? faces) (list? faces))
                  (let ([faces (reverse faces)])
                    (cons (element-start (map (lambda (e) (if (and (pair? e) (eq? (car e) 'face)) (cons 'face (car faces)) e)) value) click)
                          (map (lambda (face) (element-start (list (cons 'face face)) #f)) (cdr faces))))
                  (list (element-start value click))))])
      (values (and (pair? elements) (apply string-append elements)) (length elements))))

  (define (span-closing n)
    (if (fx= n 1)
        span-close
        (raw-html (apply string-append (make-list n "</span>")))))

  (define (span-face value)
    (let ([face (value-ref value 'face)])
      (cond
        [(symbol? face) (symbol->string face)]
        [(string? face) face]
        [else #f])))

  (define (value-ref value key)
    (and (list? value)
         (let ([e (find-first (lambda (e) (and (pair? e) (eq? (car e) key))) value)]) (and e (cdr e)))))

  ;; A span of a layer above priority 0 that the region reaches is
  ;; marked as above it and keeps its own background, as Emacs's region
  ;; overlay, with no primary priority, sits above text properties and
  ;; below an overlay with one, such as a search match.
  (define region-rank -1)

  ;; One styler serves a whole draw, so each value's attributes are made
  ;; once and a malformed entry of views:span-properties is reported once.
  (define (span-styler)
    (let ([styles (make-hashtable equal-hash equal?)] [reported '()])
      (define (malformed! key as)
        (unless (memq key reported)
          (set! reported (cons key reported))
          (report (condition (make-who-condition 'views:span-properties)
                             (make-message-condition "not a list of attribute names and values")
                             (make-irritants-condition (list key as))))))
      (lambda (value classes click)
        (let ([key (cons (cons click classes) value)])
          (or (hashtable-ref styles key #f)
              (let ([style (let-values ([(open n) (span-open value classes malformed! click)])
                             (make-span-style (and open (raw-html open)) (span-closing n)
                                              (value-ref value 'before) (value-ref value 'after) (value-ref value 'replace)))])
                (hashtable-set! styles key style)
                style))))))

  (define (styled-entry style start end rank value)
    (make-span-entry start end rank (span-style-open style) (span-style-close style)
                     (span-style-before style) (span-style-after style) (span-style-replace style)
                     (span-face value)))

  (define-record-type span-group
    (sealed #t)
    (fields priority keymap spans))

  ;; Of a source and a layer of one priority, the source is drawn inside,
  ;; so it comes after the layers in the stable sort.
  (define (span-groups b v client ws we)
    (define (source-spans source)
      (lambda ()
        (guard (c [(not (quit-condition? c)) (report c) '()])
          (let ([spans (source v client ws we)])
            (unless (and (list? spans)
                         (for-all (lambda (s) (and (list? s) (fx= (length s) 3) (fixnum? (car s)) (fixnum? (cadr s)))) spans))
              (assertion-violation 'views:span-sources "a source returned what is not a list of spans" spans))
            spans))))
    (list-sort (lambda (x y) (< (span-group-priority x) (span-group-priority y)))
               (append (map (lambda (l) (make-span-group (buffers:layer-priority l) (buffers:layer-keymap l) (lambda () (buffers:spans l ws we))))
                            (buffers:layers b v))
                       (if client
                           (map (lambda (e) (make-span-group (cdr e) #f (source-spans (car e)))) (table-entries span-sources))
                           '()))))

  (define (window-spans b v client doc regions ws we)
    (let* ([groups (span-groups b v client ws we)]
           [entries
            (let ([style (span-styler)])
              (define (span-click keymap s)
                (and keymap
                     (let ([state (click-state keymap (make-posn-record (view-record-id v) (car s) #f '() #f #f #f #f))])
                       (and state (symbol->string state)))))
              (let loop ([groups groups] [rank 0] [acc '()])
                (if (null? groups)
                    acc
                    (let ([g (car groups)])
                      (loop (cdr groups) (fx+ rank 1)
                            (fold-left
                              (lambda (acc s)
                                (let ([style (style (caddr s)
                                                    (if (and (> (span-group-priority g) 0)
                                                             (region-reaches? regions (car s) (cadr s)))
                                                        above-region
                                                        '())
                                                    (span-click (span-group-keymap g) s))])
                                  (cons (styled-entry style (car s) (cadr s) rank (caddr s)) acc)))
                              acc ((span-group-spans g))))))))]
           [pieces
            (let loop ([i 0] [acc '()])
              (if (fx= i (vector-length regions))
                  acc
                  (let ([r (vector-ref regions i)])
                    (loop (fx+ i 1)
                          (if (or (fx< (cdr r) ws) (fx> (car r) we))
                              acc
                              (append (region-pieces doc (car r) (cdr r) ws we) acc))))))])
      (list->vector (list-sort (lambda (a b) (fx< (span-entry-start a) (span-entry-start b)))
                               (append pieces entries)))))

  ;; Ranges of several cursors that overlap or meet are joined, so a line
  ;; two of them hold between them is held, and they draw one span.
  (define (region-ranges-of v doc cursors)
    (let ([n (document:length doc)])
      (define (range? r)
        (and (pair? r) (fixnum? (car r)) (fixnum? (cdr r)) (fx<= 0 (car r) (cdr r) n)))
      (let ([ranges (fold-left
                      (lambda (acc c)
                        (let ([rs (guard (e [(not (quit-condition? e)) (report e) '()])
                                    (region-ranges v c))])
                          (if (and (list? rs) (for-all range? rs))
                              (append (filter (lambda (r) (fx< (car r) (cdr r))) rs) acc)
                              (begin
                                (report (condition (make-who-condition 'views:region-ranges)
                                                   (make-message-condition "not a list of ranges in the buffer")
                                                   (make-irritants-condition (list rs))))
                                acc))))
                      '() cursors)])
        (let join ([rs (list-sort (lambda (a b) (fx< (car a) (car b))) ranges)])
          (cond
            [(or (null? rs) (null? (cdr rs))) rs]
            [(fx>= (cdar rs) (caadr rs))
             (join (cons (cons (caar rs) (fxmax (cdar rs) (cdadr rs))) (cddr rs)))]
            [else (cons (car rs) (join (cdr rs)))])))))

  (define (range-after regions position)
    (let search ([a 0] [z (vector-length regions)])
      (if (fx< a z)
          (let ([m (fxquotient (fx+ a z) 2)])
            (if (fx<= (cdr (vector-ref regions m)) position)
                (search (fx+ m 1) z)
                (search a m)))
          a)))

  (define (region-holds? regions start end)
    (let ([i (range-after regions start)])
      (and (fx< i (vector-length regions))
           (let ([r (vector-ref regions i)]) (and (fx<= (car r) start) (fx<= end (cdr r)))))))

  ;; An empty span reaches the region when the region holds its place.
  (define (region-reaches? regions start end)
    (let ([i (range-after regions start)])
      (and (fx< i (vector-length regions))
           (fx< (car (vector-ref regions i)) (fxmax end (fx+ start 1))))))

  (define region-open (raw-html "<span class=\"region\">"))
  (define region-eol-open (raw-html "<span class=\"region eol\">"))
  (define above-region '("above-region"))

  (define (region-pieces doc s e ws we)
    (let* ([first (document:line doc s)] [end-line (document:line doc e)]
           [last (if (and (fx> end-line first) (fx= e (document:line-start doc end-line))) (fx- end-line 1) end-line)]
           [from (fxmax first (document:line doc ws))] [to (fxmin last (document:line doc we))])
      (let loop ([line to] [acc '()])
        (if (fx< line from)
            acc
            (loop (fx- line 1)
                  (let ([eol? (or (fx< line last) (fx< last end-line))])
                    (cons (make-span-entry (if (fx= line first) s (document:line-start doc line))
                                           (if eol? (fx- (document:line-start doc (fx+ line 1)) 1) e)
                                           region-rank (if eol? region-eol-open region-open) span-close #f #f #f #f)
                          acc)))))))

  (define (region-piece? s) (fx= (span-entry-rank s) region-rank))

  ;; Where a node's element cuts a line's piece of the region into
  ;; fragments, only the last shows the newline, or each would.
  (define (fragment-open s from to)
    (let ([open (span-entry-open s)])
      (if (and (eq? open region-eol-open) (fx< to (span-entry-end s))) region-open open)))

  ;; A region that covers a whole node is opened around the node's
  ;; element, so drawing the node's content must not open it again.
  (define enclosing-regions (make-thread-parameter '()))

  ;; A line inside the region that holds nothing of it, an empty line or
  ;; one the region starts at the end of, still shows its newline.
  (define (empty-region-piece? s)
    (and (region-piece? s) (fx= (span-entry-start s) (span-entry-end s))))

  (define (longest-span spans)
    (let loop ([i 0] [longest 0])
      (if (fx= i (vector-length spans))
          longest
          (let ([s (vector-ref spans i)])
            (loop (fx+ i 1) (fxmax longest (fx- (span-entry-end s) (span-entry-start s))))))))

  (define (make-context v b doc client)
    (let-values ([(lo hi) (bounds-of v)])
      (let ([cs (view-client v client)])
        (let-values ([(ws we above sizer) (client-run! v doc cs)])
          (let* ([regions (list->vector (region-ranges-of v doc (view-record-cursors v)))] [spans (window-spans b v client doc regions ws we)]
                 [end (fxmin hi (fx- (document:length doc) 1))])
            (define (shown marks) (filter (lambda (m) (or (fx< (fx- ws 1) (car m) we) (fx= (car m) we end))) marks))
            (new-context v client doc lo hi ws we (document:token doc 0) (shown (cursor-points v)) (shown (anchor-points v))
                         regions spans (longest-span spans) (fold-ranges v) '() (item-ids v b) #t (make-eqv-hashtable)
                         (place-marker cs) above sizer))))))

  ;; A client's own position stands in for a placement its browser has
  ;; measured, so a view element made anew, as a tab switch makes one,
  ;; shows what that browser showed last. Following point is relative to
  ;; what a browser shows, so a new element first takes the client's own
  ;; position, or the shared one.
  (define (drawn-place cs)
    (let ([pl (client-view-placement cs)] [own (client-view-own cs)])
      (if (and own (eqv? (client-view-measured cs) (client-view-number cs)) (not (eq? (place-kind pl) 'follow)))
          own
          pl)))

  (define (place-marker cs)
    (let ([pl (drawn-place cs)])
      (and (memq (place-kind pl) '(top center bottom)) (spot-position (place-spot pl)))))

  (define (px-text x) (number->string (fl/ (flround (fl* x 100.0)) 100.0)))

  ;; The spacer below has no height of its own: it fills what the drawn
  ;; items leave of the sizer's, as the spacer above does when it is the
  ;; last, so the view's total height stays the same while it scrolls,
  ;; and a drag of the scroll bar's thumb follows the pointer.
  (define (view-html v doc ctx cs root-html)
    (let-values ([(lo hi) (item-bounds v doc)])
      (let* ([ws (context-ws ctx)] [we (context-we ctx)] [sizer (context-sizer ctx)]
             [above? (and sizer (fx> ws lo))] [below? (and sizer (fx< we hi))]
             [pl (drawn-place cs)] [kind (place-kind pl)]
             [base (and (eq? kind 'follow)
                        (or (client-view-own cs)
                            (let ([shared (view-record-place v)]) (and (eq? (place-kind shared) 'position) shared))))]
             [at (if (eq? kind 'follow) (point-of (car (view-record-cursors v))) (spot-position (place-spot pl)))]
             [item (item-start-at v doc at)]
             [base-item (and base (item-start-at v doc (spot-position (place-spot base))))])
        (define (line-at p) (let ([line (document:line doc p)]) (and (fx= p (document:line-start doc line)) line)))
        (define (position-field f) (and (eq? kind 'position) (px-text (f pl))))
        (haml
          (:div.view ([id "view-" (view-record-id v)]
                      [data-view (view-record-id v)]
                      [data-version (buffers:version (view-record-buffer v))]
                      [data-showing (view-record-shown-count v)]
                      [data-placement (client-view-number cs)]
                      [data-place-kind (symbol->string kind)]
                      [data-place-item item]
                      [data-place-line (line-at item)]
                      [data-place-at (and (not (eq? kind 'position)) at)]
                      [data-place-offset (position-field place-offset)]
                      [data-place-height (position-field place-height)]
                      [data-place-left (position-field place-left)]
                      [data-base-item base-item]
                      [data-base-line (and base-item (line-at base-item))]
                      [data-base-offset (and base (px-text (place-offset base)))]
                      [data-base-height (and base (px-text (place-height base)))]
                      [data-base-left (and base (px-text (place-left base)))]
                      [data-scroll-margin (scroll-margin)]
                      [data-reported (client-view-reported cs)]
                      [data-drawn-screens (number->string (inexact (drawn-screens)))]
                      [data-run-at-start (fx<= ws lo)]
                      [data-run-at-end (fx>= we hi)]
                      [class (and (not (wrap-lines)) "nowrap")])
            (when above?
              (:div.view-spacer ([data-spacer "above"] [aria-hidden "true"]
                                 [style "--views-spacer-block-size:" (px-text (context-above ctx)) "px"])))
            ;; The root has no element of its own, so the lines' element
            ;; carries its state.
            (:div.view-lines ([data-click (let ([root (context-root ctx)]) (and root (node-click ctx root)))]) root-html)
            (when below?
              (:div.view-spacer ([data-spacer "below"] [aria-hidden "true"])))
            (when (or above? below?)
              (:div.scroll-sizer ([aria-hidden "true"]
                                  [style "--views-scroll-sizer-block-size:" (px-text sizer) "px"]))))))))

  (define (empty-view-html v)
    (haml (:div.view ([data-view (view-record-id v)]))))

  (define failed (string->uninterned-symbol "failed"))

  (define (undefined-html ctx node inline?)
    (let ([content (if (document:atom? node) '() (children-html ctx node inline? #f))])
      (if inline?
          (haml (:span.undefined-kind content))
          (haml (:div.undefined-kind content)))))

  ;; A node's end is a search of the document's tree, and a drawn node's
  ;; is wanted by its mark, its content and the cursors after it.
  (define (node-end ctx node)
    (if (document:atom? node)
        (fx+ (document:node-start node) 1)
        (let ([ends (context-ends ctx)] [start (document:node-start node)])
          (or (hashtable-ref ends start #f)
              (let ([end (document:node-end node)])
                (hashtable-set! ends start end)
                end)))))

  ;; Each drawn node's element carries its range, so a click on it, or
  ;; past it in a line, names a position; a datum's nodes are not the
  ;; buffer's, so they carry none. A node standing alone carries an id
  ;; from an anchor at its start, as an item does: the morph matches
  ;; elements without one by their place among their siblings, and would
  ;; give a container's markup another node's content as the run changes,
  ;; carrying the browser's scroll anchor with it.
  (define (draw-node ctx node inline?)
    (mark-node ctx node inline? (node-html ctx node inline?) #f))

  ;; A cursor right before a node standing alone is drawn on the node's
  ;; elements: as a mark before it, it would take a line of its own.
  (define (mark-node ctx node inline? html cursor)
    (let ([start (document:node-start node)]
          [at-cursor (case cursor [(primary) "at-cursor primary"] [(other) "at-cursor"] [else #f])])
      (cond
        [(not (context-marks? ctx)) html]
        [inline? (haml (:span.node ([data-at start] [data-to (node-end ctx node)] [data-region (atom-in-region? ctx node)]
                                    [data-click (node-click ctx node)])
                         html))]
        [(whole-node? node)
         (haml (:div.node.whole ([id (item-id ctx start)] [class at-cursor] [data-at start] [data-to (node-end ctx node)]
                                 [data-region (atom-in-region? ctx node)] [data-click (node-click ctx node)]
                                 [data-face (covering-face ctx start (node-end ctx node))])
                 html))]
        [else (haml (:div.node ([id (item-id ctx start)] [class at-cursor] [data-at start] [data-to (node-end ctx node)]
                                [data-region (atom-in-region? ctx node)] [data-click (node-click ctx node)]
                                [data-face (covering-face ctx start (node-end ctx node))])
                      html))])))

  ;; The place a click on the node's own element names, as item-place
  ;; maps it, so the look and the click agree.
  (define (node-click ctx node)
    (let* ([kind (buffers:kind (document:node-kind node))] [keymap (and kind (buffers:kind-keymap kind))])
      (and keymap
           (let* ([start (document:node-start node)]
                  [state (click-state keymap
                           (make-posn-record (view-record-id (context-view ctx)) (if (document:atom? node) start (fx+ start 1))
                                             node '() #f #f #f #f))])
             (and state (symbol->string state))))))

  ;; A node standing alone has no characters for a span to colour, so the
  ;; innermost span covering it marks its element, which its kind's
  ;; elements are styled under.
  (define (covering-face ctx start end)
    (let loop ([spans (spans-near ctx start end)] [face #f] [rank -1])
      (if (null? spans)
          face
          (let ([s (car spans)])
            (if (and (span-entry-face s) (fx<= (span-entry-start s) start) (fx<= end (span-entry-end s))
                     (fx> (span-entry-rank s) rank))
                (loop (cdr spans) (span-entry-face s) (span-entry-rank s))
                (loop (cdr spans) face rank))))))

  (define (no-element? html)
    (cond
      [(html? html) #f]
      [(pair? html) (for-all no-element? html)]
      [else #t]))

  ;; An atom has no characters to colour, so one the region holds whole
  ;; says so itself.
  (define (atom-in-region? ctx node)
    (and (document:atom? node) (region-holds? (context-regions ctx) (document:node-start node) (node-end ctx node))))

  (define (node-html ctx node inline?)
    (let* ([kind (buffers:kind (document:node-kind node))] [draw (and kind (buffers:kind-draw kind))])
      (cond
        [draw
         (let ([html (guard (c [(not (quit-condition? c))
                                (report-as (buffers:kind-owner kind) c)
                                failed])
                       (if (eq? (in-line?) inline?)
                           (draw node (context-view ctx))
                           (parameterize ([in-line? inline?])
                             (draw node (context-view ctx)))))])
           (if (eq? html failed) (undefined-html ctx node inline?) html))]
        [(eq? (document:node-kind node) 'document:raw-byte) (raw-byte-html node)]
        [kind (if (document:atom? node) '() (children-html ctx node inline? #f))]
        [else (undefined-html ctx node inline?)])))

  ;; Buffers defines this kind, but a draw procedure there would make
  ;; buffers, a model, import faces and so the web plugin.
  (define (raw-byte-html node)
    (let ([digits (number->string (document:node-attribute node 'byte) 8)])
      (haml (:span ([data-face (symbol->string faces:escape-glyph)])
              "\\" (make-string (fx- 3 (string-length digits)) #\0) digits))))

  (define (control-char? c)
    (let ([n (char->integer c)])
      (or (and (fx< n 32) (not (fx= n 9)) (not (fx= n 10))) (fx= n 127))))

  ;; The page would show a control character as nothing, drop a NUL, and
  ;; break the line at a CR, which the event stream ends a line at. Marked
  ;; as one token, the two glyphs are one position to a click.
  (define (control-html ctx at c)
    (let ([glyph (string #\^ (integer->char (fxlogxor (char->integer c) 64)))]
          [face (symbol->string faces:escape-glyph)])
      (if (context-marks? ctx)
          (haml (:span ([data-at at] [data-to (fx+ at 1)] [data-face face]) glyph))
          (haml (:span ([data-face face]) glyph)))))

  (define (text-html ctx at str)
    (let ([n (string-length str)])
      (let loop ([i 0] [from 0] [acc '()])
        (cond
          [(fx= i n)
           (if (fx= from 0) str (reverse (if (fx< from n) (cons (substring str from n) acc) acc)))]
          [(control-char? (string-ref str i))
           (loop (fx+ i 1) (fx+ i 1)
                 (cons (control-html ctx (fx+ at i) (string-ref str i))
                       (if (fx< from i) (cons (substring str from i) acc) acc)))]
          [else (loop (fx+ i 1) from acc)]))))

  (define-record-type text-piece (sealed #t) (fields at string))
  (define-record-type fold-mark (sealed #t) (fields at to))

  (define (items-of ctx node s e)
    (let ([folds (context-folds ctx)] [items '()])
      (define (fold-mark! f)
        (unless (memq f (context-shown ctx))
          (context-shown-set! ctx (cons f (context-shown ctx)))
          (set! items (cons (make-fold-mark (car f) (cdr f)) items))))
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
             (let* ([ns (document:node-start child)] [ne (node-end ctx child)]
                    [f (find-first (lambda (f) (and (fx<= (car f) ns) (fx<= ne (cdr f)))) folds)])
               (if f (fold-mark! f) (set! items (cons child items))))])))
      (reverse items)))

  (define (children-html ctx node inline? wrap)
    (let* ([cs (fx+ (document:node-start node) 1)] [ce (fx- (node-end ctx node) 1)]
           [s (fxmax cs (context-lo ctx) (if inline? 0 (context-ws ctx)))]
           [e (fxmin ce (context-hi ctx) (if inline? ce (context-we ctx)))])
      (cond
        [(fx> s e) '()]
        [(and inline? (context-marks? ctx))
         (haml (:span ([data-at s]) (line-content ctx (items-of ctx node s e) s e)))]
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
      (define (as-line run rs re class line at-start? acc)
        (cons (wrapped rs (line-html ctx line (if (pair? run) (item-start (car run)) rs) class at-start?
                                     (line-content ctx run rs re) (exists text-piece? run)))
              acc))
      (let loop ([items items] [run '()] [rs s] [known #f] [acc '()])
        (cond
          [(null? items)
           (let ([run (reverse run)])
             (reverse
               (cond
                 [(or (exists text-piece? run) (and (pair? run) (for-all fold-mark? run)))
                  (as-line run rs e #f (or known (document:line doc rs)) known acc)]
                 [(pair? run) (append (reverse (block-items ctx run rs e wrapped)) acc)]
                 [(or (and root? (fx= e ce)) (pair? (cursors-in ctx rs e)) (pair? (anchors-in ctx rs e))) (as-line run rs e #f (or known (document:line doc rs)) known acc)]
                 [else acc])))]
          [(text-piece? (car items))
           (let ([at (text-piece-at (car items))] [str (text-piece-string (car items))])
             (let split ([from 0] [run run] [rs rs] [known known] [acc acc])
               (let ([nl (newline-index str from)])
                 (if nl
                     (let ([run (reverse (if (fx= nl from) run (cons (make-text-piece (fx+ at from) (substring str from nl)) run)))]
                           [line (or known (document:line doc rs))])
                       (split (fx+ nl 1) '() (fx+ at nl 1) (and (for-all text-piece? run) (fx+ line 1))
                              (as-line run rs (fx+ at nl) (held-line-class ctx rs (fx+ at nl 1)) line known acc)))
                     (loop (cdr items)
                           (cond
                             [(fx= from 0) (cons (car items) run)]
                             [(fx= from (string-length str)) run]
                             [else (cons (make-text-piece (fx+ at from) (substring str from (string-length str))) run)])
                           rs known acc)))))]
          [else (loop (cdr items) (cons (car items) run) rs known acc)]))))

  (define (item-start item)
    (cond
      [(text-piece? item) (text-piece-at item)]
      [(fold-mark? item) (fold-mark-at item)]
      [else (document:node-start item)]))

  ;; A line the region holds through its newline, or a folded block it
  ;; holds whole, is marked, so the stylesheet fills the line to its
  ;; edges, as Emacs extends the region face: a line's edges are the
  ;; browser's to know.
  (define (held-line-class ctx start end)
    (and (region-holds? (context-regions ctx) start end) "region-line"))

  (define (line-html ctx line rs class at-start? content text?)
    (haml (:div.line ([id (and (context-marks? ctx) (item-id ctx rs))]
                      [class class]
                      [data-line line]
                      [data-at (and (not at-start?) (context-marks? ctx)
                                    (not (fx= rs (document:line-start (context-doc ctx) line)))
                                    rs)])
            content
            (unless text? (:br)))))

  ;; A placement's place in text is the row box of a mark styled as the
  ;; cursor: an empty element has no box of its own, and a different one
  ;; in each browser.
  (define view-place-html (haml (:span.view-place)))

  (define (cursor-html primary?)
    (if primary? (haml (:span.cursor.primary)) (haml (:span.cursor))))

  (define (anchor-html a)
    (haml (:span.view-anchor ([style "--views-anchor-name:--view-anchor-" (anchor-record-id a)]))))

  (define (fold-html ctx f)
    (if (context-marks? ctx)
        (haml (:span.fold ([data-at (fold-mark-at f)] [data-to (fold-mark-to f)]) "…"))
        (haml (:span.fold "…"))))

  (define (block-items ctx run rs re wrapped)
    (let loop ([items run] [cursors (cursors-in ctx rs re)] [anchors (anchors-in ctx rs re)] [acc '()])
      (define (before p q acc cursors anchors)
        (cond
          [(and (pair? anchors) (fx<= (caar anchors) q) (not (and (pair? cursors) (fx< (caar cursors) (caar anchors)))))
           (before p q (cons (cdar anchors) acc) cursors (cdr anchors))]
          [(and (pair? cursors) (fx<= (caar cursors) p))
           (before p q (cons (cursor-html (cdar cursors)) acc) (cdr cursors) anchors)]
          [else (values acc cursors anchors)]))
      (define (cursor-at p cursors cursor)
        (if (and (pair? cursors) (fx= (caar cursors) p))
            (cursor-at p (cdr cursors) (if (or (eq? cursor 'primary) (cdar cursors)) 'primary 'other))
            (values cursors cursor)))
      (define (past p marks)
        (if (and (pair? marks) (fx< (caar marks) p)) (past p (cdr marks)) marks))
      (if (null? items)
          (let-values ([(acc cursors anchors) (before re re acc cursors anchors)]) (reverse acc))
          (let ([item (car items)])
            (if (fold-mark? item)
                (let-values ([(acc cursors anchors) (before (fold-mark-at item) (fold-mark-at item) acc cursors anchors)])
                  (loop (cdr items) cursors anchors
                        (cons (wrapped (fold-mark-at item)
                                       (line-html ctx (document:line (context-doc ctx) (fold-mark-at item)) (fold-mark-at item)
                                                  (held-line-class ctx (fold-mark-at item) (fold-mark-to item)) #f
                                                  (fold-html ctx item) #t))
                              acc)))
                (let*-values ([(start) (document:node-start item)]
                              [(acc cursors anchors) (before (fx- start 1) start acc cursors anchors)]
                              [(cursors cursor) (cursor-at start cursors #f)])
                  (let* ([html (node-html ctx item #f)] [on-item? (and cursor (not (no-element? html)))] [end (node-end ctx item)])
                    (loop (cdr items) (past end cursors) (past end anchors)
                          (cons (wrapped item (mark-node ctx item #f html (and on-item? cursor)))
                                (if (and cursor (not on-item?)) (cons (cursor-html (eq? cursor 'primary)) acc) acc))))))))))

  (define (cursors-in ctx lo hi)
    (filter (lambda (m) (fx<= lo (car m) hi)) (context-cursors ctx)))

  (define (anchors-in ctx lo hi)
    (filter (lambda (m) (fx<= lo (car m) hi)) (context-anchors ctx)))

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
                 [sub (new-context (context-view ctx) (context-client ctx) doc 0 n 0 n #f '() '() '#() '#() 0 '() '() #f #f (make-eqv-hashtable) #f #f #f)])
            (parameterize ([current-context sub])
              (let loop ([p 0] [acc '()])
                (if (fx>= p n)
                    (reverse acc)
                    (let ([t (document:token doc p)])
                      (if (document:node? t)
                          (loop (document:node-end t) (cons (draw-node sub t #t) acc))
                          (loop (fx+ p 1) acc))))))))))

  (define (marked-datum ctx datum at to)
    (let ([html (datum-html ctx datum)])
      (if (context-marks? ctx)
          (haml (:span.datum ([data-at at] [data-to to]) html))
          html)))

  ;; A cursor or span datum inside an inline node is the node's own to
  ;; draw, so the line passes over it.
  (define (line-content ctx items rs re)
    (let ([spans (let ([near (spans-near ctx rs re)] [open (enclosing-regions)])
                   (if (null? open) near (remp (lambda (s) (memq s open)) near)))]
          [cursors (cursors-in ctx rs re)]
          [anchors (let ([at (context-marker ctx)] [as (anchors-in ctx rs re)])
                     (if (and at (fx<= rs at re)) (cons (cons at view-place-html) as) as))])
      (cond
        [(and (null? spans) (null? cursors) (null? anchors))
         (map (lambda (item)
                (cond
                  [(document:node? item) (draw-node ctx item #t)]
                  [(text-piece? item) (text-html ctx (text-piece-at item) (text-piece-string item))]
                  [else (fold-html ctx item)]))
              items)]
        [(and (null? cursors) (null? anchors) (for-all text-piece? items) (flat? spans)) (flat-content ctx items spans)]
        [else
          (let ([insertions (list-sort
                               (lambda (a b) (or (fx< (insertion-at a) (insertion-at b))
                                                 (and (fx= (insertion-at a) (insertion-at b)) (fx< (insertion-order a) (insertion-order b)))))
                               (filter (lambda (i) (fx<= rs (insertion-at i) re))
                                       (append
                                         (fold-left
                                           (lambda (acc s)
                                             (define (datum d at to) (lambda () (marked-datum ctx d at to)))
                                             (let* ([start (span-entry-start s)] [end (span-entry-end s)]
                                                    [acc (if (span-entry-before s)
                                                             (cons (make-insertion start 0 (datum (span-entry-before s) start start) #f) acc)
                                                             acc)]
                                                    [acc (if (span-entry-replace s)
                                                             (cons (make-insertion start 1 (datum (span-entry-replace s) start end) s) acc)
                                                             acc)]
                                                    [acc (if (empty-region-piece? s)
                                                             (cons (make-insertion start 4 (lambda () (list (fragment-open s start end) (span-entry-close s))) #f) acc)
                                                             acc)])
                                               (if (span-entry-after s)
                                                   (cons (make-insertion end 2 (datum (span-entry-after s) end end) #f) acc)
                                                   acc)))
                                           '() spans)
                                         (map (lambda (m) (make-insertion (car m) 3 (lambda () (cdr m)) #f)) anchors)
                                         (map (lambda (m) (make-insertion (car m) 3 (lambda () (cursor-html (cdr m))) #f)) cursors))))]
                [solid (filter (lambda (s) (fx< (span-entry-start s) (span-entry-end s))) spans)]
                [pieces '()])
            (define shown (by-rank (filter span-entry-open solid)))
            (define (add! stack from to html) (set! pieces (cons (make-content-piece stack from to html) pieces)))
            ;; A line can hold thousands of spans, as a search's matches in
            ;; a long line do, so the spans that can hold a place are kept
            ;; as the places go forward, rather than all searched each time.
            (define pending (list-sort (lambda (a b) (fx< (span-entry-start a) (span-entry-start b))) shown))
            (define active '())
            (define last-place -1)
            (define (candidates p)
              (if (fx< p last-place)
                  shown
                  (begin
                    (set! last-place p)
                    (let take ()
                      (when (and (pair? pending) (fx<= (span-entry-start (car pending)) p))
                        (set! active (cons (car pending) active))
                        (set! pending (cdr pending))
                        (take)))
                    (set! active (filter (lambda (s) (fx>= (span-entry-end s) p)) active))
                    (by-rank active))))
            (define (covering p q)
              (filter (lambda (s) (and (fx<= (span-entry-start s) p) (fx>= (span-entry-end s) q))) (candidates p)))
            (define (inside p)
              (filter (lambda (s) (fx< (span-entry-start s) p (span-entry-end s))) (candidates p)))
            (define replacing (filter span-entry-replace solid))
            (define (replaced? p q)
              (exists (lambda (s) (and (fx<= (span-entry-start s) p) (fx>= (span-entry-end s) q))) replacing))
            (define (emit-insertions! upto)
              (when (and (pair? insertions) (fx<= (insertion-at (car insertions)) upto))
                (let ([i (car insertions)])
                  (set! insertions (cdr insertions))
                  (let ([s (insertion-span i)] [at (insertion-at i)])
                    (if s
                        (add! (covering (span-entry-start s) (span-entry-end s)) (span-entry-start s) (span-entry-end s) ((insertion-html i)))
                        (add! (inside at) at at ((insertion-html i)))))
                  (emit-insertions! upto))))
            (let ([cuts (list-sort fx< (append (map insertion-at insertions)
                                               (fold-left (lambda (acc s) (cons* (span-entry-start s) (span-entry-end s) acc))
                                                          '() solid)))])
              (for-each
                (lambda (item)
                  (cond
                    [(document:node? item)
                     (let ([ns (document:node-start item)] [ne (node-end ctx item)])
                       (emit-insertions! ns)
                       (set! insertions (remp (lambda (i) (fx< ns (insertion-at i) ne)) insertions))
                       (let* ([stack (covering ns ne)] [regions (filter region-piece? stack)])
                         (add! stack ns ne
                               (if (null? regions)
                                   (draw-node ctx item #t)
                                   (parameterize ([enclosing-regions (append regions (enclosing-regions))])
                                     (draw-node ctx item #t))))))]
                    [(text-piece? item)
                     (let* ([at (text-piece-at item)] [str (text-piece-string item)] [z (fx+ at (string-length str))])
                       (let loop ([a at] [cuts (filter (lambda (c) (fx< at c z)) cuts)])
                         (let ([b (if (null? cuts) z (car cuts))])
                           (emit-insertions! a)
                           (unless (replaced? a b)
                             (add! (covering a b) a b (text-html ctx a (substring str (fx- a at) (fx- b at)))))
                           (unless (null? cuts)
                             (loop b (let drop ([cs (cdr cuts)]) (if (and (pair? cs) (fx= (car cs) b)) (drop (cdr cs)) cs)))))))]
                    [else
                     (emit-insertions! (fold-mark-at item))
                     (add! '() (fold-mark-at item) (fold-mark-to item) (fold-html ctx item))]))
                items))
            (emit-insertions! re)
            (nest (reverse pieces) 0))])))

  ;; Text that is no buffer's is drawn as a line of its own, with no
  ;; cursors, anchors or marks, so its spans follow the rule a buffer's do.
  (define (text-spans-html v client text spans)
    (let* ([n (string-length text)] [style (span-styler)]
           [entries (let loop ([spans spans] [rank 0] [acc '()])
                      (if (null? spans)
                          acc
                          (let ([s (car spans)])
                            (loop (cdr spans) (fx+ rank 1)
                                  (cons (styled-entry (style (caddr s) '() #f) (car s) (cadr s) rank (caddr s)) acc)))))]
           [sorted (list->vector (list-sort (lambda (a b) (fx< (span-entry-start a) (span-entry-start b))) entries))]
           [ctx (new-context v client #f 0 n 0 n #f '() '() '#() sorted (longest-span sorted) '() '() #f #f
                             (make-eqv-hashtable) #f #f #f)])
      (parameterize ([current-context ctx] [enclosing-regions '()])
        (line-content ctx (list (make-text-piece 0 text)) 0 n))))

  ;; Highlighting's spans seldom overlap: a line whose spans are apart,
  ;; with no cursor or datum in it, draws each span as one element.
  (define (flat? spans)
    (let loop ([spans spans] [end -1])
      (or (null? spans)
          (let ([s (car spans)])
            (cond
              [(or (span-entry-before s) (span-entry-after s) (span-entry-replace s) (empty-region-piece? s)) #f]
              [(or (not (span-entry-open s)) (fx= (span-entry-start s) (span-entry-end s))) (loop (cdr spans) end)]
              [(fx< (span-entry-start s) end) #f]
              [else (loop (cdr spans) (span-entry-end s))])))))

  (define (flat-content ctx items spans)
    (let ([spans (filter (lambda (s) (and (span-entry-open s) (fx< (span-entry-start s) (span-entry-end s)))) spans)])
      (let next ([items items] [spans spans] [acc '()])
        (if (null? items)
            (reverse acc)
            (let* ([at (text-piece-at (car items))] [str (text-piece-string (car items))] [z (fx+ at (string-length str))])
              (let loop ([a at] [spans spans] [acc acc])
                (cond
                  [(or (null? spans) (fx>= (span-entry-start (car spans)) z))
                   (next (cdr items) spans (if (fx< a z) (cons (text-html ctx a (substring str (fx- a at) (fx- z at))) acc) acc))]
                  [(fx<= (span-entry-end (car spans)) a) (loop a (cdr spans) acc)]
                  [else
                   (let* ([s (car spans)] [from (fxmax a (span-entry-start s))] [to (fxmin z (span-entry-end s))]
                          [acc (if (fx< a from) (cons (text-html ctx a (substring str (fx- a at) (fx- from at))) acc) acc)]
                          [acc (cons (list (fragment-open s from to) (text-html ctx from (substring str (fx- from at) (fx- to at))) (span-entry-close s)) acc)])
                     (if (fx<= (span-entry-end s) z)
                         (loop to (cdr spans) acc)
                         (next (cdr items) spans acc)))])))))))

  (define span-close (raw-html "</span>"))

  (define (nest pieces depth)
    (let loop ([pieces pieces] [acc '()])
      (if (null? pieces)
          (reverse acc)
          (let ([stack (list-tail (content-piece-stack (car pieces)) depth)])
            (if (null? stack)
                (loop (cdr pieces) (cons (content-piece-html (car pieces)) acc))
                (let ([s (car stack)])
                  (let take ([rest pieces] [run '()])
                    (if (and (pair? rest)
                             (let ([t (list-tail (content-piece-stack (car rest)) depth)]) (and (pair? t) (eq? (car t) s))))
                        (take (cdr rest) (cons (car rest) run))
                        (loop rest (cons (list (fragment-open s (content-piece-from (car pieces)) (content-piece-to (car run)))
                                               (nest (reverse run) (fx+ depth 1))
                                               (span-entry-close s))
                                         acc))))))))))

  (define (shown-buffer who v)
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
        (let ([c (make-cursor-record v (point-spot b (stop-within b lo hi p)) #f #f)])
          (view-record-cursors-set! v (append (view-record-cursors v) (list c)))
          (mark-dirty!)
          c))))

  (define (add-fold! v start end)
    (let ([b (view-record-buffer v)])
      (view-record-folds-set! v (append (view-record-folds v) (list (cons (make-spot b start #t) (make-spot b end #f)))))
      (estimate-range! v b start end)
      (mark-dirty!)))

  ;; A sizer is kept only so a thumb drag does not change the length under
  ;; it; a fold or narrowing changes the view's length, and a view at rest
  ;; sends no report to drop the sizer.
  (define (estimate-range! v b start end)
    (let* ([doc (buffers:document b)] [count (counter doc)])
      (vector-for-each
        (lambda (d) (update-maps! d (document:length doc) (lambda (m) (height-map-replace! m start end end count))))
        (hashtable-values (view-record-devices v)))
      (for-each-client-view (lambda (c cs) (client-view-sizer-set! cs #f)) v)))

  ;; A quit can land between two maps' updates, so a map that missed one
  ;; no longer fits the document; it goes, and the next report makes it
  ;; again.
  (define (update-maps! d length update!)
    (device-view-maps-set! d
      (filter (lambda (e) (and (fx= (height-map-length (cdr e)) length) (begin (update! (cdr e)) #t)))
              (device-view-maps d))))

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
      (estimate-range! v b start start)
      (estimate-range! v b end end)
      (let ([t (spot-position (place-spot (view-record-place v)))])
        (unless (fx<= start t end)
          (scroll-to-place! v start 'top)))
      (primary-moved! v)
      (mark-dirty!)))

  (define (widen-view! v)
    (let* ([b (bound-buffer v)] [r (view-record-narrowing v)])
      (view-record-narrowing-set! v #f)
      (when (and b r)
        (estimate-range! v b (spot-position (car r)) (spot-position (car r)))
        (estimate-range! v b (spot-position (cdr r)) (spot-position (cdr r))))
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

  (define (draw-view v client)
    (let ([b (bound-buffer v)])
      (if (not b)
          (empty-view-html v)
          (with-view-bound v b
            (lambda ()
              (open-folds-at-cursors! v)
              (let ([doc (buffers:document b)])
                (when (view-record-moved? v) (follow-point! v))
                (let ([ctx (make-context v b doc client)])
                  (parameterize ([current-context ctx] [in-line? #f] [drawing (cons v (drawing))])
                    (let ([cs (view-client v client)])
                      (client-view-drawn-batch-set! cs batches)
                      (view-html v doc ctx cs (node-html ctx (context-root ctx) #f)))))))))))

  (define (top-position v doc c)
    (let* ([cs (and c (hashtable-ref (view-record-clients v) c #f))] [own (and cs (current-own cs))])
      (if own
          (spot-position (place-spot own))
          (item-start-at v doc (spot-position (place-spot (view-record-place v)))))))

  ;; A part of a cell that does not fit is no column or row.
  (define (body-size-in v c)
    (let* ([cs (hashtable-ref (view-record-clients v) c #f)] [f (and cs (or (client-view-facts cs) (client-view-sized cs)))])
      (if f
          (values (fxmax 1 (flonum->fixnum (flfloor (fl/ (fixnum->flonum (facts-width f)) (facts-char-width f)))))
                  (fxmax 1 (flonum->fixnum (flfloor (fl/ (fixnum->flonum (facts-height f)) (facts-line-height f))))))
          (values #f #f))))

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

  ;; The copy's height maps are its own, made by its first report: a view
  ;; with other folds has other items, and an edit updates each view's
  ;; maps, so a shared one twice.
  (define (copy-place! from to)
    (let ([b (bound-buffer from)])
      (when (and b (eq? b (bound-buffer to)))
        (view-record-cursors-set! to
          (map (lambda (c) (make-cursor-record to (point-spot b (point-of c))
                                               (let ([m (mark-of c)]) (and m (make-spot b m #f)))
                                               (cursor-record-goal c)))
               (view-record-cursors from)))
        (place-all! to (let ([pl (view-record-place from)]) (place-at pl (make-spot b (spot-position (place-spot pl)) #f))) #f)
        (for-each-client-view
          (lambda (c old)
            (let ([own (client-view-own old)])
              (when own
                (let ([copy (view-client to c)])
                  (client-view-own-set! copy (place-at own (make-spot b (spot-position (place-spot own)) #f)))
                  (send-placement! copy (client-view-own copy))))))
          from))))

  (define (span-keymap value)
    (let ([entry (and (list? value) (assq 'keymap value))])
      (and entry (table? (cdr entry)) (cdr entry))))

  (define (keymaps-at v b p)
    (let ([doc (buffers:document b)])
      (append
        (fold-left
          (lambda (acc l)
            (let* ([spans (append (buffers:spans-at l p)
                                  (filter (lambda (s) (and (fx<= (car s) p) (fx< p (cadr s))))
                                          (buffers:spans l p (fxmin (fx+ p 1) (document:length doc)))))]
                   [own (fold-left (lambda (ks s) (let ([k (span-keymap (caddr s))]) (if (and k (not (memq k ks))) (append ks (list k)) ks)))
                                   '() spans)]
                   [keymap (buffers:layer-keymap l)])
              (append own (if (and keymap (pair? spans)) (list keymap) '()) acc)))
          '() (buffers:layers b v))
        (let* ([t (document:token doc p)] [kind (and (document:node? t) (document:atom? t) (buffers:kind (document:node-kind t)))]
               [keymap (and kind (buffers:kind-keymap kind))])
          (if keymap (list keymap) '()))
        (let loop ([n (document:enclosing doc p)] [acc '()])
          (if n
              (loop (document:enclosing doc (document:node-start n))
                    (let* ([kind (buffers:kind (document:node-kind n))] [keymap (and kind (buffers:kind-keymap kind))])
                      (if keymap (cons keymap acc) acc)))
              (reverse acc))))))

  (define own-options
    (list (cons 'drawn-screens drawn-screens) (cons 'scroll-margin scroll-margin) (cons 'wrap-lines wrap-lines)
          (cons 'cursor-visible cursor-visible) (cons 'hand-scroll-moves-point hand-scroll-moves-point)))

  (define (position? p) (and (fixnum? p) (fx>= p 0)))

  (define (range? r) (and (pair? r) (position? (car r)) (position? (cdr r))))

  (define (saved-place? p)
    (or (eq? p 'follow)
        (and (list? p) (fx= (length p) 4) (position? (car p)) (for-all flonum? (cdr p)))))

  (define (entry? e)
    (and (list? e) (fx= (length e) 7)
         (let-values ([(id name place cursors folds narrowing options) (apply values e)])
           (and (fixnum? id) (fx> id 0) (string? name) (saved-place? place)
                (pair? cursors) (list? cursors)
                (for-all (lambda (c) (and (pair? c) (position? (car c)) (or (not (cdr c)) (position? (cdr c))))) cursors)
                (list? folds) (for-all range? folds)
                (or (not narrowing) (range? narrowing))
                (list? options) (for-all (lambda (o) (and (pair? o) (assq (car o) own-options))) options)))))

  (define (saved-state? x)
    (or (null? x) (and (pair? x) (fixnum? (car x)) (list? (cdr x)) (for-all entry? (cdr x)))))

  (define-saved state '() saved-state?)

  (define (entry-of v)
    (list (view-record-id v) (view-record-name v)
          (if (eq? (view-record-moved-last v) 'followed)
              'follow
              (let ([pl (view-record-place v)] [round (lambda (x) (fl/ (flround (fl* x 100.0)) 100.0))])
                (list (spot-position (place-spot pl)) (round (place-offset pl)) (round (place-height pl))
                      (round (place-left pl)))))
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
            (let-values ([(id name place cursors folds narrowing options) (apply values e)])
              (unless (find-view id)
                (let ([v (make-view-record id name #f (if (eq? place 'follow)
                                                          (make-place 'position 0 0.0 0.0 0.0)
                                                          (apply make-place 'position place))
                                           folds narrowing #t)])
                  (unless (eq? place 'follow) (view-record-moved-last-set! v 'scrolled))
                  (view-record-cursors-set! v (map (lambda (c) (make-cursor-record v (car c) (cdr c) #f)) cursors))
                  (add-view! v)
                  (for-each
                    (lambda (o)
                      (guard (c [(not (quit-condition? c)) (report c)])
                        (set-view-option! 'views:set-option! v (cdr (assq (car o) own-options)) (cdr o) #f)))
                    options)))))
          (cdr saved))
        (set! dirty? #f))))

  ;; Histories and last points change with every edit of a buffer they
  ;; hold, and building them costs far more than a view's own entry, so
  ;; they are saved apart, at idle and when the plugin unloads, not after
  ;; every batch with the views.
  (define (saved-entry? e)
    (and (list? e) (fx= (length e) 5)
         (let-values ([(name place cursors folds narrowing) (apply values e)])
           (and (string? name) (saved-place? place)
                (pair? cursors) (list? cursors)
                (for-all (lambda (c) (and (pair? c) (position? (car c)) (or (not (cdr c)) (position? (cdr c))))) cursors)
                (list? folds) (for-all range? folds)
                (or (not narrowing) (range? narrowing))))))

  (define (saved-histories? x)
    (and (pair? x) (list? (car x)) (list? (cdr x))
         (for-all (lambda (h) (and (list? h) (fx= (length h) 3) (fixnum? (car h))
                                   (list? (cadr h)) (for-all saved-entry? (cadr h))
                                   (list? (caddr h)) (for-all string? (caddr h))))
                  (car x))
         (for-all (lambda (p) (and (pair? p) (string? (car p)) (position? (cdr p)))) (cdr x))))

  (define-saved histories '(()) saved-histories?)

  (define (place-datum moved-last pl)
    (if (eq? moved-last 'followed)
        'follow
        (let ([round (lambda (x) (fl/ (flround (fl* x 100.0)) 100.0))])
          (list (spot-position (place-spot pl)) (round (place-offset pl)) (round (place-height pl)) (round (place-left pl))))))

  (define (kept-datum k)
    (list (let ([b (kept-buffer k)]) (if b (buffers:name b) (kept-name k)))
          (place-datum (kept-moved-last k) (kept-place k))
          (map (lambda (pm) (cons (spot-position (car pm)) (and (cdr pm) (spot-position (cdr pm))))) (kept-cursors k))
          (map (lambda (f) (cons (spot-position (car f)) (spot-position (cdr f))))
               (filter (lambda (f) (fx< (spot-position (car f)) (spot-position (cdr f)))) (kept-folds k)))
          (let ([n (kept-narrowing k)]) (and n (cons (spot-position (car n)) (spot-position (cdr n)))))))

  (define (write-histories!)
    (set! history-dirty? #f)
    (let* ([kept (fold-right
                   (lambda (v acc)
                     (if (view-record-saved? v)
                         (cons (list (view-record-id v)
                                     (map kept-datum (filter (lambda (k) (or (kept-now k) (not (kept-buffer k))))
                                                             (view-record-previous v)))
                                     (map (lambda (x) (if (string? x) x (buffers:name x)))
                                          (filter (lambda (x) (or (string? x) (buffers:live? x))) (view-record-next v))))
                               acc)
                         acc))
                   '() views)]
           [points (fold-right
                     (lambda (b acc) (let ([p (last-point-of b)]) (if p (cons (cons (buffers:name b) p) acc) acc)))
                     '() (buffers:all))]
           [waiting (let-values ([(names ps) (hashtable-entries waiting-points)])
                      (filter (lambda (np) (not (buffers:find (car np))))
                              (map cons (vector->list names) (vector->list ps))))]
           [now (cons kept (append points (list-sort (lambda (a b) (string<? (car a) (car b))) waiting)))])
      (unless (equal? now (histories))
        (set-saved! histories now))))

  ;; A start makes its buffers again before it first idles, so an entry
  ;; or a last point still waiting then names a buffer that is gone, and
  ;; keeping it would grow the saved histories at every restart.
  (define waiting? #t)

  (define (forget-waiting!)
    (set! waiting? #f)
    (for-each
      (lambda (v)
        (view-record-previous-set! v (filter kept-now (view-record-previous v)))
        (view-record-next-set! v (next-now v)))
      views)
    (vector-for-each
      (lambda (name) (unless (buffers:find name) (hashtable-delete! waiting-points name)))
      (hashtable-keys waiting-points))
    (set! history-dirty? #t))

  (define (restore-histories!)
    (let ([saved (histories)])
      (for-each
        (lambda (h)
          (let ([v (find-view (car h))])
            (when v
              (view-record-previous-set! v
                (map (lambda (e)
                       (let-values ([(name place cursors folds narrowing) (apply values e)])
                         (make-kept #f name cursors
                           (if (eq? place 'follow) (make-place 'position 0 0.0 0.0 0.0) (apply make-place 'position place))
                           (if (eq? place 'follow) 'followed 'scrolled) folds narrowing '())))
                     (cadr h)))
              (view-record-next-set! v (caddr h)))))
        (car saved))
      (for-each (lambda (np) (hashtable-set! waiting-points (car np) (cdr np))) (cdr saved))))

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
    (set! history-dirty? #t)
    (let ([vs (hashtable-ref by-buffer buffer '())])
      (unless (null? vs)
        (set! dirty? #t)
        (unless (memq buffer edited) (set! edited (cons buffer edited)))
        (for-each
          (lambda (v)
            (unless (null? (cdr (view-record-cursors v)))
              (merge-cursors! v)))
          vs)
        (let ([inserted (buffers:piece-length (buffers:edit-inserted edit))])
          (when (and (fx> inserted 0) (point-after-insertion?))
            (let ([end (fx+ (buffers:edit-start edit) inserted)])
              (for-each
                (lambda (v)
                  (when (fx= (point-of (car (view-record-cursors v))) end)
                    (primary-moved! v)))
                vs))))
        (when (exists (lambda (v) (fx> (hashtable-size (view-record-devices v)) 0)) vs)
          (update-edited-maps! vs buffer edit)))))

  (define (update-edited-maps! vs buffer edit)
    (let* ([start (buffers:edit-start edit)]
           [old-end (fx+ start (buffers:piece-length (buffers:edit-removed edit)))]
           [new-end (fx+ start (buffers:piece-length (buffers:edit-inserted edit)))]
           [doc (buffers:document buffer)]
           [before (fx- (document:length doc) (fx- new-end old-end))]
           [count (counter doc)])
      (for-each
        (lambda (v)
          (vector-for-each
            (lambda (d) (update-maps! d before (lambda (m) (height-map-replace! m start old-end new-end count))))
            (hashtable-values (view-record-devices v))))
        vs)))

  (define (note-kill buffer)
    (for-each (lambda (v) (when (eq? (view-record-host v) buffer) (drop-view! v))) views)
    (for-each
      (lambda (v)
        (unless (replace-buffer-in! v 'kill)
          (set-shown-buffer! v #f)
          (reset-view! v #f)))
      (hashtable-ref by-buffer buffer '()))
    (for-each (lambda (v) (forget-in-history! v buffer)) views)
    (eq-hashtable-delete! movers buffer)
    (eq-hashtable-delete! left-points buffer)
    (hashtable-delete! waiting-points (buffers:name buffer)))

  (define (after-batch ended)
    (ended)
    (for-each drop-undrawn-items! views)
    (set! batches (fx+ batches 1))
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

  ;; No browser lays out a box past about 3.4e7 px (Chrome's limit), so a
  ;; larger measure is no browser's.
  (define most-px 100000000)

  ;; A report's number goes back on its client's next screen whatever
  ;; becomes of the report, since its page sends no other until then.
  (define (scroll-report c item)
    (define (field key) (let ([e (assoc key item)]) (if e (cdr e) 'null)))
    (define (px? x) (and (real? x) (<= (abs x) most-px)))
    (define (extent? x) (and (real? x) (<= 0 x most-px)))
    (define (size? x) (and (fixnum? x) (fx<= 0 x most-px)))
    (define (mark? m)
      (and (list? m) (pair? m)
           (for-all (lambda (e)
                      (and (pair? e) (member (car e) '("line" "at" "token" "count")) (fixnum? (cdr e))
                           (fx>= (cdr e) (if (equal? (car e) "line") 1 0))))
                    m)))
    (define (item? x) (and (vector? x) (fx= (vector-length x) 2) (mark? (vector-ref x 0)) (extent? (vector-ref x 1))))
    (define (mark-or-null? x) (or (eq? x 'null) (mark? x)))
    (let ([id (field "view")] [placement (field "placement")] [number (field "report")] [version (field "version")]
          [top (field "top")] [offset (field "offset")] [item-height (field "itemHeight")] [left (field "left")]
          [start (field "start")] [end (field "end")] [spacer (field "spacer")] [distance (field "spacerDistance")]
          [below (field "below")] [items (field "items")] [line-height (field "lineHeight")] [char-width (field "charWidth")]
          [width (field "width")] [height (field "height")] [settled (field "settled")] [hand (field "hand")]
          [at-end (field "runAtEnd")])
      (unless (and (fixnum? id) (fixnum? placement) (fixnum? number) (fixnum? version) (fx>= version 0)
                   (mark-or-null? top) (px? offset) (extent? item-height) (extent? left)
                   (mark-or-null? start) (mark-or-null? end)
                   (member spacer '("above" "below" null)) (extent? distance) (extent? below)
                   (vector? items) (for-all item? (vector->list items))
                   (extent? line-height) (> line-height 0) (extent? char-width) (> char-width 0)
                   (size? width) (size? height) (boolean? settled) (boolean? hand) (boolean? at-end))
        (assertion-violation 'views "not a scroll report" item))
      (let ([v (find-view id)])
        (when v
          (let ([cs (view-client v c)])
            (client-view-reported-set! cs number)
            (let ([b (bound-buffer v)])
              (when (and b (fx= placement (client-view-number cs)) (fx> height 0) (fx> width 0)
                         (fx<= version (buffers:version b)))
                (let ([r (make-measured placement version (and (pair? top) top) (inexact offset) (inexact item-height)
                                      (inexact left) (and (pair? start) start) (and (pair? end) end)
                                      (and (string? spacer) (string->symbol spacer)) (inexact distance)
                                      (map (lambda (x) (cons (vector-ref x 0) (inexact (vector-ref x 1)))) (vector->list items))
                                      (inexact line-height) (inexact char-width) width height settled hand at-end
                                      (inexact below))])
                  (with-view-bound v b
                    (lambda ()
                      (when (view-record-moved? v)
                        (follow-point! v))
                      (when (fx= placement (client-view-number cs))
                        (after-report! v b cs (adopt-report! v b c cs r)))))))))))))

  ;; A stale press is kept too, so the release after it reports nothing
  ;; more.
  (define presses (make-weak-eq-hashtable))

  ;; A press holds the view's showing count because its anchor is in the
  ;; buffer shown then; a release on a screen showing another buffer must
  ;; not pair with it. Its posn gives a drag's start all but the position,
  ;; which the anchor keeps.
  (define-record-type mouse-press
    (sealed #t)
    (fields view showing anchor posn))

  ;; Nongenerative, so an event made before this module reloads still
  ;; holds a posn its accessors take.
  (define-record-type posn-record
    (nongenerative views:posn/view/point/node/keymaps/x/y/column/row)
    (sealed #t)
    (fields view point node keymaps x y column row))

  ;; The page holds no Scheme value, so it names a marked keymap by a
  ;; number. Both tables hold the keymap weakly, so a keymap made for a
  ;; while, as a temporary one, goes when nothing else holds it. A weak
  ;; pair frees the keymap but not its entry, so a guardian gives back
  ;; the number of each keymap the collector drops.
  (define keymap-ids (make-weak-eq-hashtable))
  (define id-keymaps (make-eqv-hashtable))
  (define dropped-keymap-ids (make-guardian))
  (define last-keymap-id 0)

  (define (forget-dropped-keymaps!)
    (let ([id (dropped-keymap-ids)])
      (when id
        (hashtable-delete! id-keymaps id)
        (forget-dropped-keymaps!))))

  (define (keymap-id keymap)
    (forget-dropped-keymaps!)
    (or (eq-hashtable-ref keymap-ids keymap #f)
        (let ([id (fx+ last-keymap-id 1)])
          (set! last-keymap-id id)
          (eq-hashtable-set! keymap-ids keymap id)
          (hashtable-set! id-keymaps id (weak-cons keymap #f))
          (dropped-keymap-ids keymap id)
          id)))

  ;; An element's look comes from the lookup a left click on it runs, so
  ;; a keymap that answers first, as a disabled button's, decides it.
  ;; Only a keymap that binds the left button itself is asked: the global
  ;; keymap answers a click anywhere in text.
  (define left-click-keys '("<mouse-1>" "<down-mouse-1>"))

  (define (runs-something? found)
    (and found (not (eq? found keys:ignore)) (not (eq? found keys:undefined))))

  ;; A posn with no place leaves out the keymaps a click finds by place,
  ;; so only the keymap's own bindings, which a click searches first,
  ;; can make it inert.
  (define (click-state keymap posn)
    (and (exists (lambda (key) (table-ref keymap key #f)) left-click-keys)
         (let* ([keymaps (keys:active-keymaps #f posn)]
                [found (map (lambda (key) (keys:lookup-in keymaps key)) left-click-keys)]
                [placed? (posn-record-view posn)])
           (cond
             [(exists (lambda (key f)
                        (let ([own (keys:lookup-in (list keymap) key)])
                          (and (commands:command? own) (runs-something? own) (commands:command? f) (runs-something? f))))
                      left-click-keys found)
              'clickable]
             [(for-all (lambda (key f)
                         (if placed?
                             (not (runs-something? f))
                             (let ([own (keys:lookup-in (list keymap) key)]) (and own (not (runs-something? own))))))
                       left-click-keys found)
              'inert]
             [else #f]))))

  (define (marked-keymap id)
    (let ([entry (and (fixnum? id) (hashtable-ref id-keymaps id #f))])
      (and entry (table? (car entry)) (car entry))))

  (define (marked-keymaps ids)
    (if (vector? ids)
        (fold-right (lambda (id acc) (let ([keymap (marked-keymap id)]) (if keymap (cons keymap acc) acc)))
                    '() (vector->list ids))
        '()))

  (define (stale-click)
    (raise-continuable
      (condition (make-warning) (make-message-condition "Stale click: what was clicked is gone"))))

  (define (malformed item)
    (assertion-violation 'views:mouse-item "not a mouse item" item))

  (define (edit-delta e)
    (fx- (buffers:piece-length (buffers:edit-inserted e)) (buffers:piece-length (buffers:edit-removed e))))

  ;; A position names the gap before a token, so it follows that token,
  ;; and is gone with it.
  (define (follow p edits)
    (let loop ([p p] [es edits])
      (if (null? es)
          p
          (let* ([e (car es)] [s (buffers:edit-start e)] [removed (buffers:piece-length (buffers:edit-removed e))])
            (cond
              [(fx< p s) (loop p (cdr es))]
              [(fx< p (fx+ s removed)) #f]
              [else (loop (fx+ p (edit-delta e)) (cdr es))])))))

  (define (document-then doc edits)
    (fold-right
      (lambda (e doc)
        (let ([s (buffers:edit-start e)])
          (document:replace doc s (fx+ s (buffers:piece-length (buffers:edit-inserted e))) (buffers:piece-document (buffers:edit-removed e)))))
      doc edits))

  (define (item-place b item field)
    (let ([version (field "version")] [token (field "token")] [at (field "at")] [line (field "line")]
          [count (field "count")])
      (unless (and (fixnum? version) (fx<= 0 version (buffers:version b)))
        (malformed item))
      (if (not (or token at line))
          (values #f #f)
          (let ([edits (buffers:edits-since b version)])
            (if (not edits)
                (values 'stale #f)
                (let* ([doc (buffers:document b)]
                       [size (fold-left (lambda (n e) (fx- n (edit-delta e))) (document:length doc) edits)]
                       [count? (and (fixnum? count) (fx>= count 0))]
                       [p (cond
                            [token (and (fixnum? token) token)]
                            [at (and (fixnum? at) (fx>= at 0) count? (fx+ at count))]
                            [else
                             (and (fixnum? line) (fx> line 0) count?
                                  (let ([then (if (null? edits) doc (document-then doc edits))])
                                    (and (fx<= line (document:line then (document:length then)))
                                         (fx+ (document:line-start then line) count))))])])
                  (unless (and p (fx<= 0 p) (fx< p size))
                    (malformed item))
                  (let ([now (follow p edits)])
                    (if (not now)
                        (values 'stale #f)
                        (let ([t (and token (document:token doc now))])
                          (cond
                            [(not (document:node? t)) (values now #f)]
                            [(document:atom? t) (values now t)]
                            [else (values (fx+ now 1) t)]))))))))))

  ;; The cell is counted in what the sending client last measured of the
  ;; view, when the item arrives, so the page sends only facts.
  (define (item-posn v c id p node item field)
    (let ([x (field "x")] [y (field "y")] [keymaps (marked-keymaps (field "keymaps"))])
      (if (and (real? x) (real? y))
          (let* ([cs (and v (hashtable-ref (view-record-clients v) c #f))] [f (and cs (client-view-facts cs))])
            (define (cell at size) (exact (max 0 (floor (/ at size)))))
            (make-posn-record id p node keymaps x y
                              (and f (cell x (facts-char-width f))) (and f (cell y (facts-line-height f)))))
          (make-posn-record id p node keymaps #f #f #f #f))))

  (define (mouse-item c item)
    (define (field key) (let ([e (assoc key item)]) (and e (cdr e))))
    (let* ([action (field "action")] [id (field "view")] [v (and (fixnum? id) (fx> id 0) (find-view id))])
      ;; The page sends no other move or scroll report for the view until
      ;; a screen brings this number back.
      (when (and v (equal? action "move"))
        (let ([n (field "report")])
          (unless (fixnum? n) (malformed item))
          (client-view-reported-set! (view-client v c) n)))
      (let ([key (keys:item-key item)] [showing (field "showing")])
        (unless (and (fixnum? id) (fx> id 0) (fixnum? showing))
          (malformed item))
        (let*-values ([(b) (and v (fx= showing (view-record-shown-count v)) (bound-buffer v))]
                      [(p node) (if b (item-place b item field) (values 'stale #f))]
                      [(press) (let ([pr (eq-hashtable-ref presses c #f)])
                                 (and pr (eq? (mouse-press-view pr) v) (fx= (mouse-press-showing pr) showing) pr))])
          (define (posn) (item-posn v c id p node item field))
          (define (run! event)
            (with-view-bound v b (lambda () (keys:press! c event))))
          (cond
            [(equal? action "move")
             (unless (or (not p) (eq? p 'stale))
               (run! (list key (posn))))]
            [(equal? action "wheel")
             (if (eq? p 'stale) (stale-click) (run! (list key (posn))))]
            [(equal? action "down")
             (if (eq? p 'stale)
                 (begin (when v (eq-hashtable-set! presses c (make-mouse-press v showing 'stale #f))) (stale-click))
                 (let ([at (posn)])
                   (eq-hashtable-set! presses c (make-mouse-press v showing (and p (buffers:anchor b p)) at))
                   (run! (list key at))))]
            [else
             (eq-hashtable-delete! presses c)
             (cond
               [(and press (eq? (mouse-press-anchor press) 'stale)) (void)]
               [(equal? action "click")
                (if (eq? p 'stale) (stale-click) (run! (list key (posn))))]
               [(and press b)
                (let* ([start (mouse-press-anchor press)] [from (mouse-press-posn press)])
                  (run! (list key
                              (make-posn-record id (and start (buffers:anchor-position start)) (posn-record-node from)
                                                (posn-record-keymaps from) (posn-record-x from) (posn-record-y from)
                                                (posn-record-column from) (posn-record-row from))
                              (if (eq? p 'stale) (item-posn v c id #f #f item field) (posn)))))]
               [else (stale-click)])])))))

  (define (posn-keymaps posn)
    (let* ([ok? (posn-record? posn)]
           [v (and ok? (find-view (posn-record-view posn)))]
           [b (and v (bound-buffer v))]
           [p (and ok? (posn-record-point posn))])
      (if (and b (fixnum? p) (fx<= 0 p (buffer-length b)))
          (keymaps-at v b p)
          '())))

  (define (face-attributes face)
    (cond
      [(symbol? face) (list (cons "data-face" (symbol->string face)))]
      [(string? face) (list (cons "data-face" face))]
      [else '()]))

  (define (title-attributes title)
    (if (string? title) (list (cons "title" title)) '()))

  (record-writer (record-type-descriptor posn-record)
    (lambda (r p wr) (fprintf p "#<posn ~a ~a>" (posn-record-view r) (posn-record-point r))))

  (record-writer (record-type-descriptor view-record)
    (lambda (v p wr) (fprintf p "#<view ~a>" (view-record-id v))))

  (record-writer (record-type-descriptor cursor-record)
    (lambda (c p wr) (fprintf p "#<cursor>")))

  (restore!)
  (restore-histories!)
  (run-with-idle-timer 1
    (lambda ()
      (when waiting? (forget-waiting!))
      (when history-dirty? (write-histories!))))
  (on-unload write-histories!))

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
  (bound-buffer view)
  (switch-buffer! view buffer))

(define (previous-buffers view)
  (check-view 'views:previous-buffers view)
  (previous-buffers-of view))

(define (previous-buffer! view)
  (check-view 'views:previous-buffer! view)
  (bound-buffer view)
  (previous-buffer-in! view))

(define (next-buffer! view)
  (check-view 'views:next-buffer! view)
  (bound-buffer view)
  (next-buffer-in! view))

(define (replace-buffer! view)
  (check-view 'views:replace-buffer! view)
  (bound-buffer view)
  (replace-buffer-in! view 'bury))

(define (last-point buffer)
  (check-main-thread 'views:last-point)
  (check-live-buffer 'views:last-point buffer)
  (last-point-of buffer))

(define (set-last-point! buffer position)
  (check-main-thread 'views:set-last-point!)
  (check-live-buffer 'views:set-last-point! buffer)
  (unless (and (fixnum? position) (fx<= 0 position (document:length (buffers:document buffer))))
    (assertion-violation 'views:set-last-point! "not a position in the buffer" position))
  (set-last-point-of! buffer position))

(define (preview-buffer! view buffer)
  (check-view 'views:preview-buffer! view)
  (check-live-buffer 'views:preview-buffer! buffer)
  (bound-buffer view)
  (preview-in! view buffer))

(define (end-preview! view)
  (check-view 'views:end-preview! view)
  (end-preview-in! view))

(define (previewing? view)
  (check-view 'views:previewing? view)
  (previewing-in? view))

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

(define (showing buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'views:showing "not a buffer" buffer))
  (check-main-thread 'views:showing)
  (views-showing buffer))

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
  (shown-buffer 'views:set-point! view)
  (check-position 'views:set-point! view position)
  (move-point! view (car (view-record-cursors view)) position)
  (primary-moved! view))

(define (mark view)
  (check-view 'views:mark view)
  (bound-buffer view)
  (mark-of (car (view-record-cursors view))))

(define (set-mark! view position)
  (check-view 'views:set-mark! view)
  (shown-buffer 'views:set-mark! view)
  (when position (check-position 'views:set-mark! view position))
  (let ([c (car (view-record-cursors view))])
    (set-cursor-spots! c (point-of c) position)))

(define (cursors view)
  (check-view 'views:cursors view)
  (bound-buffer view)
  (view-record-cursors view))

(define (add-cursor! view position)
  (check-view 'views:add-cursor! view)
  (shown-buffer 'views:add-cursor! view)
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

(define (region-ranges view cursor)
  (check-view 'views:region-ranges view)
  (check-cursor 'views:region-ranges cursor)
  (bound-buffer view)
  (let ([p (point-of cursor)] [m (mark-of cursor)])
    (if (and m (not (fx= p m)))
        (list (cons (fxmin p m) (fxmax p m)))
        '())))

(define region-bounds
  (case-lambda
    [(view)
     (check-view 'views:region-bounds view)
     (%region-bounds view (view-record-cursors view))]
    [(view cursor)
     (check-view 'views:region-bounds view)
     (check-cursor 'views:region-bounds cursor)
     (unless (eq? (cursor-record-view cursor) view)
       (assertion-violation 'views:region-bounds "not a cursor of the view" cursor))
     (%region-bounds view (list cursor))]))

(define (%region-bounds view cs)
  (let ([b (bound-buffer view)])
    (if b
        (with-view-bound view b (lambda () (region-ranges-of view (buffers:document b) cs)))
        '())))

(define (set-cursor! cursor point mark)
  (check-cursor 'views:set-cursor! cursor)
  (let ([view (cursor-record-view cursor)])
    (unless (memq cursor (view-record-cursors view))
      (assertion-violation 'views:set-cursor! "not a cursor of the view" cursor))
    (shown-buffer 'views:set-cursor! view)
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
  (let ([b (shown-buffer 'views:next-stop view)])
    (check-position 'views:next-stop view position)
    (stop-after view b position)))

(define (previous-stop view position)
  (check-view 'views:previous-stop view)
  (let ([b (shown-buffer 'views:previous-stop view)])
    (check-position 'views:previous-stop view position)
    (stop-before view b position)))

(define top
  (case-lambda
    [(view) (top view (web:current-client))]
    [(view client)
     (check-view 'views:top view)
     (unless (or (not client) (web:client? client))
       (assertion-violation 'views:top "not a client or #f" client))
     (let ([b (bound-buffer view)])
       (if b (top-position view (buffers:document b) client) 0))]))

(define (body-size view client)
  (check-view 'views:body-size view)
  (unless (web:client? client)
    (assertion-violation 'views:body-size "not a client" client))
  (body-size-in view client))

(define (scroll-to! view position alignment)
  (check-view 'views:scroll-to! view)
  (shown-buffer 'views:scroll-to! view)
  (check-position 'views:scroll-to! view position)
  (unless (memq alignment '(top center bottom))
    (assertion-violation 'views:scroll-to! "not an alignment" alignment))
  (scroll-to-place! view position alignment))

(define (%commanded who scroll)
  (let ([v (current-view)])
    (unless v
      (assertion-violation who "no current view"))
    (let ([b (shown-buffer who v)] [c (web:current-client)])
      (scroll v b c (view-client v c)))))

(commands:define-command (scroll-up)
  "Scrolls the current view forward by its height less two lines, as the browser of the client whose key ran it shows it."
  (%commanded 'views:scroll-up
    (lambda (v b c cs) (when-measured! cs (lambda () (scroll-by! v b c cs #t))))))

(commands:define-command (scroll-down)
  "Scrolls the current view back by its height less two lines, as the browser of the client whose key ran it shows it."
  (%commanded 'views:scroll-down
    (lambda (v b c cs) (when-measured! cs (lambda () (scroll-by! v b c cs #f))))))

(commands:define-command (recenter-top-bottom)
  "Puts point at the centre of the current view; repeated, at the top, then the bottom."
  (%commanded 'views:recenter-top-bottom
    (lambda (v b c cs) (recenter! v b (eq? (commands:last-command) recenter-top-bottom)))))

(define (fold! view start end)
  (check-view 'views:fold! view)
  (shown-buffer 'views:fold! view)
  (check-position 'views:fold! view start)
  (check-position 'views:fold! view end)
  (unless (fx<= start end)
    (assertion-violation 'views:fold! "the start is after the end" start end))
  (add-fold! view start end))

(define (unfold! view position)
  (check-view 'views:unfold! view)
  (let ([b (shown-buffer 'views:unfold! view)])
    (check-position 'views:unfold! view position)
    (let-values ([(opened kept) (partition (lambda (f) (fx<= (spot-position (car f)) position (spot-position (cdr f))))
                                           (live-folds view))])
      (view-record-folds-set! view kept)
      (for-each (lambda (f) (estimate-range! view b (spot-position (car f)) (spot-position (cdr f)))) opened)))
  (mark-dirty!))

(define (folds-at view position)
  (check-view 'views:folds-at view)
  (shown-buffer 'views:folds-at view)
  (check-position 'views:folds-at view position)
  (fold-right (lambda (f acc)
                (let ([start (spot-position (car f))] [end (spot-position (cdr f))])
                  (if (fx<= start position end) (cons (cons start end) acc) acc)))
              '() (live-folds view)))

(define (folded? view position)
  (check-view 'views:folded? view)
  (shown-buffer 'views:folded? view)
  (check-position 'views:folded? view position)
  (exists (lambda (f) (fx<= (spot-position (car f)) position (spot-position (cdr f)))) (live-folds view)))

(define (narrow! view start end)
  (check-view 'views:narrow! view)
  (shown-buffer 'views:narrow! view)
  (check-position 'views:narrow! view start)
  (check-position 'views:narrow! view end)
  (unless (fx<= start end)
    (assertion-violation 'views:narrow! "the start is after the end" start end))
  (narrow-view! view start end))

(define (widen! view)
  (check-view 'views:widen! view)
  (widen-view! view))

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

(define (%drawn-for)
  (let ([ctx (current-context)]) (and ctx (context-client ctx))))

(define (%draw-view-atom node view)
  (let ([inner (atom-view-of node (bound-buffer view))])
    (if (drawing? inner) '() (draw inner (%drawn-for)))))

(buffers:define-kind view (content atom) (draw %draw-view-atom))

(define (atom-view node)
  (check-main-thread 'views:atom-view)
  (check-node 'views:atom-view node)
  (atom-view-of node #f))

(define (draw-text view text spans)
  (check-view 'views:draw-text view)
  (unless (string? text)
    (assertion-violation 'views:draw-text "not a string" text))
  (unless (and (list? spans)
               (for-all (lambda (s) (and (list? s) (fx= (length s) 3) (fixnum? (car s)) (fixnum? (cadr s))
                                         (fx<= 0 (car s) (cadr s) (string-length text))))
                        spans))
    (assertion-violation 'views:draw-text "not a list of spans in the text" spans))
  (let ([client (%drawn-for)])
    (with-view-bound view (bound-buffer view) (lambda () (text-spans-html view client text spans)))))

(define (draw view client)
  (check-view 'views:draw view)
  (unless (or (not client) (web:client? client))
    (assertion-violation 'views:draw "not a client or #f" client))
  (draw-view view client))

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
                 (children-html (make-context view b (buffers:document b) (%drawn-for)) node #f wrap)
                 '()))))]))

(define (keymaps view)
  (check-view 'views:keymaps view)
  (let ([b (bound-buffer view)])
    (if b (keymaps-at view b (point-of (car (view-record-cursors view)))) '())))

(define (describe-line node view)
  (check-view 'views:describe-line view)
  (check-node 'views:describe-line node)
  (let* ([doc (buffers:document (shown-buffer 'views:describe-line view))] [p (point-of (car (view-record-cursors view)))]
         [start (document:node-start node)] [line (document:line doc p)]
         [lines (fx+ (fx- line (document:line doc start)) 1)])
    (if (column-number)
        (let ([chars (document:unit characters)])
          (format "~a:~a" lines
            (fx- (document:offset doc p chars)
                 (document:offset doc (if (fx= lines 1) start (document:line-start doc line)) chars))))
        (format "L~a" lines))))

(define (%describer kind)
  (let loop ([es (table-entries position-describers)])
    (cond
      [(null? es) #f]
      [(eq? (buffers:constructor-kind (caar es)) kind) (cdar es)]
      [else (loop (cdr es))])))

(define (describe-at-point view)
  (check-view 'views:describe-at-point view)
  (let ([b (bound-buffer view)])
    (and b
         (let* ([doc (buffers:document b)] [p (point-of (car (view-record-cursors view)))]
                [t (document:token doc p)]
                [atom (and (document:node? t) (document:atom? t) t)])
           (let loop ([n (or atom (document:enclosing doc p))])
             (cond
               [(not n) (call-with-view view (lambda () (describe-line (document:token doc 0) view)))]
               [(let ([kind (buffers:kind (document:node-kind n))]) (and kind (%describer kind)))
                => (lambda (describe) (call-with-view view (lambda () (describe n view))))]
               [else (loop (document:enclosing doc (document:node-start n)))]))))))

(define-option position-description describe-at-point (lambda (v) (or (not v) (procedure? v)))
  "A procedure of a view that returns what describes where its primary point is, or #f to show none.")

(define (%scroll-report client item) (scroll-report client item))

(define (%mouse-item client item) (mouse-item client item))

(define (%posn-keymaps client posn) (if posn (posn-keymaps posn) '()))

(define (%marked-keymaps client posn)
  (if (posn-record? posn) (posn-record-keymaps posn) '()))

(define (keymap-mark keymap)
  (unless (table? keymap)
    (assertion-violation 'views:keymap-mark "not a keymap" keymap))
  (check-main-thread 'views:keymap-mark)
  (let ([id (number->string (keymap-id keymap))])
    (case (click-state keymap (make-posn-record #f #f #f (list keymap) #f #f #f #f))
      [(clickable) (string-append id " clickable")]
      [(inert) (string-append id " inert")]
      [else id])))

(define (shown-count view)
  (check-view 'views:shown-count view)
  (view-record-shown-count view))

(define (%check-posn who posn)
  (unless (posn-record? posn)
    (assertion-violation who "not a position of a mouse key" posn)))

(define %make-posn
  (case-lambda
    [(view position) (%make-posn view position #f '() #f #f)]
    [(view position node keymaps column row)
     (check-view 'views:%make-posn view)
     (make-posn-record (view-record-id view) position node keymaps #f #f column row)]))

(define (posn-view posn)
  (%check-posn 'views:posn-view posn)
  (find-view (posn-record-view posn)))

(define (posn-point posn)
  (%check-posn 'views:posn-point posn)
  (posn-record-point posn))

(define (posn-node posn)
  (%check-posn 'views:posn-node posn)
  (posn-record-node posn))

(define (posn-x-y posn)
  (%check-posn 'views:posn-x-y posn)
  (values (posn-record-x posn) (posn-record-y posn)))

(define (posn-cell posn)
  (%check-posn 'views:posn-cell posn)
  (values (posn-record-column posn) (posn-record-row posn)))

(define (%check-anchor who a)
  (unless (anchor-record? a)
    (assertion-violation who "not an anchor" a))
  (when (anchor-record-gone? a)
    (assertion-violation who "a removed anchor" a))
  (check-main-thread who))

(define (add-anchor! view position)
  (check-view 'views:add-anchor! view)
  (let ([b (shown-buffer 'views:add-anchor! view)])
    (check-position 'views:add-anchor! view position)
    (new-anchor! view b position)))

(define (anchor? v) (anchor-record? v))

(define (anchor-id anchor)
  (%check-anchor 'views:anchor-id anchor)
  (anchor-record-id anchor))

(define (anchor-view anchor)
  (%check-anchor 'views:anchor-view anchor)
  (anchor-record-view anchor))

(define (anchor-position anchor)
  (%check-anchor 'views:anchor-position anchor)
  (spot-position (anchor-record-spot anchor)))

(define (move-anchor! anchor position)
  (%check-anchor 'views:move-anchor! anchor)
  (check-position 'views:move-anchor! (anchor-record-view anchor) position)
  (buffers:set-anchor! (anchor-record-spot anchor) position)
  (mark-dirty!))

(define (remove-anchor! anchor)
  (unless (anchor-record? anchor)
    (assertion-violation 'views:remove-anchor! "not an anchor" anchor))
  (check-main-thread 'views:remove-anchor!)
  (forget-anchor! anchor))

(define (find-anchor id)
  (unless (fixnum? id)
    (assertion-violation 'views:find-anchor "not an anchor number" id))
  (check-main-thread 'views:find-anchor)
  (anchor-of-id id))

(define (anchor-drawn? anchor client)
  (%check-anchor 'views:anchor-drawn? anchor)
  (unless (web:client? client)
    (assertion-violation 'views:anchor-drawn? "not a client" client))
  (anchor-drawn-for? anchor client))

(define (%check-scroller who s)
  (unless (scroller-record? s)
    (assertion-violation who "not a scroller" s))
  (when (scroller-record-dropped? s)
    (assertion-violation who "a dropped scroller" s))
  (check-main-thread who))

(define (%check-item who x)
  (unless (and (fixnum? x) (fx> x 0))
    (assertion-violation who "not an item number" x)))

(define (make-scroller on-rest)
  (unless (procedure? on-rest)
    (assertion-violation 'views:make-scroller "not a procedure" on-rest))
  (check-main-thread 'views:make-scroller)
  (make-new-scroller! on-rest))

(define (scroller? v) (scroller-record? v))

(define (place-scroller! scroller item alignment focus)
  (%check-scroller 'views:place-scroller! scroller)
  (%check-item 'views:place-scroller! item)
  (%check-item 'views:place-scroller! focus)
  (unless (memq alignment '(start end center nearest))
    (assertion-violation 'views:place-scroller! "not a scroller alignment" alignment))
  (set-scroller-place! scroller item alignment focus))

(define (scroller-focus scroller)
  (%check-scroller 'views:scroller-focus scroller)
  (scroller-record-focus scroller))

(define (scroller-in-view scroller client)
  (%check-scroller 'views:scroller-in-view scroller)
  (unless (web:client? client)
    (assertion-violation 'views:scroller-in-view "not a client" client))
  (let ([cs (hashtable-ref (scroller-record-clients scroller) client #f)])
    (and cs (scroller-state-in-view cs))))

(define (scroller-wholly-in-view scroller client)
  (%check-scroller 'views:scroller-wholly-in-view scroller)
  (unless (web:client? client)
    (assertion-violation 'views:scroller-wholly-in-view "not a client" client))
  (let ([cs (hashtable-ref (scroller-record-clients scroller) client #f)])
    (and cs (scroller-state-whole cs))))

(define (draw-scroller scroller client axis class content)
  (%check-scroller 'views:draw-scroller scroller)
  (unless (web:client? client)
    (assertion-violation 'views:draw-scroller "not a client" client))
  (unless (memq axis '(row column))
    (assertion-violation 'views:draw-scroller "not an axis" axis))
  (unless (string? class)
    (assertion-violation 'views:draw-scroller "not a string" class))
  (let ([cs (scroller-client scroller client)])
    (haml (:div ([class class] [data-scroller (scroller-record-id scroller)] [data-axis (symbol->string axis)]
                 [data-placement (scroller-state-number cs)]
                 [data-place-item (scroller-record-item scroller)]
                 [data-place-align (symbol->string (scroller-record-align scroller))]
                 [data-place-focus (scroller-record-focus scroller)]
                 [data-reported (scroller-state-reported cs)])
            content))))

(define (drop-scroller! scroller)
  (unless (scroller-record? scroller)
    (assertion-violation 'views:drop-scroller! "not a scroller" scroller))
  (check-main-thread 'views:drop-scroller!)
  (forget-scroller! scroller))

(define (%scroller-report client item) (scroller-report client item))

(table-set! span-properties 'face face-attributes)
(table-set! span-properties 'title title-attributes)
(table-set! web:scripts 'views "views/views.js")
(table-set! web:early-scripts 'views "views/place.js")
(table-set! web:stylesheets 'views "views/views.css")
(table-set! web:input-handlers "scroll" %scroll-report)
(table-set! web:input-handlers "mouse" %mouse-item)
(table-set! web:input-handlers "scroller" %scroller-report)
(add-hook! keys:find-keymaps %posn-keymaps)
;; The keymaps marked around the element clicked come before every other
;; keymap at the position.
(add-hook! keys:find-keymaps %marked-keymaps -100)
(add-hook! web:client-removed forget-client!)
(keys:bind! keys:global "C-v" scroll-up)
(keys:bind! keys:global "<next>" scroll-up)
(keys:bind! keys:global "M-v" scroll-down)
(keys:bind! keys:global "<prior>" scroll-down)
(keys:bind! keys:global "C-l" recenter-top-bottom)
(add-hook! buffers:after-edit note-edit)
(add-hook! buffers:killed note-kill)
(advice-add! batch-ended after-batch)
