;;; Memo (ADR 17): drawing a piece of a screen again only when something it
;;; read changed. A library (ADR 12): it uses only the public kernel API.
;;;
;;; A source is a revision that its owner replaces whenever the state it
;;; stands for changes (`source-changed!`); readers of that state call
;;; `record-read!` in the owner's accessors, so drawing code never mentions
;;; revisions. `(memo key inputs draw)` draws one piece: it returns the
;;; value kept for KEY when that value was drawn from `equal?` INPUTS and
;;; nothing it read has changed since, and otherwise calls (DRAW INPUTS)
;;; and keeps what it returns. INPUTS are plain data (`plain-value?` in
;;; tuna/lib/plain-data): the values the piece's parent worked out for it.
;;; DRAW may close over the objects KEY identifies (ids are never reused)
;;; and nothing else. Pieces nest: a piece read whatever its child pieces
;;; read, so an unchanged subtree is reused by one check.
;;;
;;; Pieces are kept per cache (one per drawer), and each pass draws for
;;; one client. A piece that read a per-client source is that client's;
;;; any other is shared by every client. A piece lives while the last pass
;;; of some client used it, itself or as a descendant of a reused piece.
;;;
;;; Test mode (`set-memo-checking!`) draws every pass a second time from
;;; scratch and fails when the two differ; it also fails a source write or
;;; a `check-not-drawing!` while drawing, a key used twice in one pass, and
;;; inputs that are not plain data. Drawing happens on the baton only.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/lib/plain-data)
(export source source? new-source source-revision
        record-read! source-changed!
        memo-drawing? memo-from-scratch? check-not-drawing!
        memo-cache memo-cache? new-memo-cache memo-cache-size
        call-with-memo-pass memo memo-forget-client!
        current-memo-draw-observer
        set-memo-checking! memo-checking?)

;;; Sources

;; NOTED-IN is the last frame that recorded the source, so a frame records
;; each source once.
(defstruct source ((revision    : :fixnum)
                   (per-client? : :boolean)
                   (noted-in    : :fixnum))
  final: #t)

;; A source; PER-CLIENT? when it stands for what one client measured, so
;; that a piece reading it belongs to that client.
(def (new-source per-client?: (per-client? : :boolean := #f)) => source
  (make-source (next-id!) per-client? 0))

;;; Test mode

(def checking? #f)

(def (set-memo-checking! (on? : :boolean)) => :void
  (set! checking? on?))

(def (memo-checking?) => :boolean
  checking?)

;; A procedure called with the key of each piece drawn through a cache,
;; not reused and not drawn from scratch; #f for none. For tests and
;; benchmarks counting what a pass drew.
(def current-memo-draw-observer (make-parameter #f))

;;; Pieces, frames and passes

;; One drawing of KEY from INPUTS: VALUE, and READS, the (source .
;; revision) pairs and child pieces it read. CLIENT is its client when
;; PER-CLIENT?. CHECKED is the pass that last found whether it is current
;; (FOUND-CURRENT?); USERS counts the clients whose last pass used it. Never
;; changed once drawn but for those three.
(defclass piece ((key         : :t)
                 (inputs      : :t)
                 (per-client? : :boolean)
                 (client      : :t)
                 (reads       : :list)
                 (value       : :t)
                 (checked     : :fixnum)
                 (found-current? : :boolean)
                 (users       : :fixnum))
  final: #t)

;; PIECES: key -> the pieces kept for it. CLIENTS: client -> the pieces
;; its last pass used (piece -> #t).
(defclass memo-cache ((pieces  : HashTable)
                      (clients : HashTable))
  final: #t)

(def (new-memo-cache) => memo-cache
  (memo-cache pieces: (make-hash-table) clients: (make-hash-table-eq)))

;; How many pieces CACHE keeps.
(def (memo-cache-size (cache : memo-cache)) => :fixnum
  (hash-fold (lambda (key (variants : :list) (count : :fixnum)) (fx+ count (length variants)))
             0 cache.pieces))

;; One pass: drawing for CLIENT through CACHE, or from scratch when CACHE
;; is #f. MARKED holds the pieces it used; KEYS, in test mode, the keys.
(defclass memo-pass ((cache  :? memo-cache)
                     (client : :t)
                     (number : :fixnum)
                     (marked : HashTable)
                     (keys   :? HashTable))
  final: #t)

;; What one piece being drawn has read so far.
(defclass frame ((id          : :fixnum)
                 (pass        : memo-pass)
                 (reads       : :list)
                 (per-client? : :boolean))
  final: #t)

(def current-memo-frame (make-parameter #f))

(def last-frame-id 0)

(def (new-frame (pass : memo-pass)) => frame
  (set! last-frame-id (fx1+ last-frame-id))
  (frame id: last-frame-id pass: pass reads: [] per-client?: #f))

;; Whether this thread is drawing a pass.
(def (memo-drawing?) => :boolean
  (and (current-memo-frame) #t))

;; Whether this thread is drawing a pass from scratch: test mode's second
;; drawing, which tests that count what is drawn leave out.
(def (memo-from-scratch?) => :boolean
  (let (f (current-memo-frame))
    (and f (not (memo-pass-cache (frame-pass f))))))

;; In test mode, fail when this thread is drawing: WHAT writes state.
(def (check-not-drawing! (what : :symbol)) => :void
  (when (and checking? (current-memo-frame))
    (error "Drawing must not write state" what)))

;;; Reads and writes

(def (record-read! (s : source)) => :void
  (let (f (current-memo-frame))
    (when f
      (using ((f : frame) (s : source))
        (unless (fx= s.noted-in f.id)
          (set! s.noted-in f.id)
          (set! f.reads (cons (cons s s.revision) f.reads))
          (when s.per-client?
            (set! f.per-client? #t)))))))

;; S's state changed: give it a new revision. Never while drawing.
(def (source-changed! (s : source)) => :void
  (check-not-drawing! 'source-changed!)
  (set! (source-revision s) (next-id!)))

;;; Drawing

;; Whether P, and every piece it read, read only sources that have not
;; changed since; worked out once per pass NUMBER.
(def (piece-current? (p : piece) (number : :fixnum)) => :boolean
  (if (fx= p.checked number)
    p.found-current?
    (let (current? (let lp ((reads p.reads))
                     (match reads
                       ([] #t)
                       ([read . more]
                        (and (if (pair? read)
                               (fx= (source-revision (car read)) (: (cdr read) :fixnum))
                               (piece-current? read number))
                             (lp more))))))
      (set! p.checked number)
      (set! p.found-current? current?)
      current?)))

;; Mark P, and every piece below it, used by PASS.
(def (mark! (pass : memo-pass) (p : piece)) => :void
  (unless (hash-key? pass.marked p)
    (hash-put! pass.marked p #t)
    (for-each (lambda (read) (unless (pair? read) (mark! pass read))) p.reads)))

;; In test mode, the checks on a piece's KEY and INPUTS.
(def (check-piece! (pass : memo-pass) (key : :t) (inputs : :t)) => :void
  (let (keys pass.keys)
    (when keys
      (when (hash-key? keys key)
        (error "A memo key was drawn twice in one pass" key))
      (hash-put! keys key #t)))
  (unless (plain-value? inputs)
    (error "Memo inputs must be plain data" key)))

;; Draw (DRAW INPUTS) as a piece in its own frame of PASS.
(def (draw-piece (pass : memo-pass) (key : :t) (inputs : :t) (draw : :procedure)) => piece
  (let* ((f (new-frame pass))
         (value (parameterize ((current-memo-frame f)) (draw inputs))))
    (using (f : frame)
      (piece key: key inputs: inputs per-client?: f.per-client? client: (and f.per-client? pass.client)
             reads: f.reads value: value checked: pass.number found-current?: #t users: 0))))

;; The piece KEY drawn from INPUTS by DRAW, kept or drawn again (see the
;; header). Call only while drawing a pass.
(def (memo (key : :t) (inputs : :t) (draw : :procedure)) => :t
  (let (f (current-memo-frame))
    (unless f
      (error "memo draws only inside call-with-memo-pass" key))
    (using ((f : frame) (pass (frame-pass f) : memo-pass))
      (when checking?
        (check-piece! pass key inputs))
      (let (cache pass.cache)
        (if cache
          (using (cache : memo-cache)
            (let* ((kept (find (lambda ((p : piece))
                                 (and (or (not p.per-client?) (eq? p.client pass.client))
                                      (equal? p.inputs inputs)
                                      (piece-current? p pass.number)))
                               (hash-ref cache.pieces key [])))
                   (p (or kept
                          (let (observe (current-memo-draw-observer))
                            (when observe (observe key))
                            (draw-piece pass key inputs draw)))))
              (using (p : piece)
                (if kept
                  (mark! pass p)
                  (hash-put! pass.marked p #t))
                (set! f.reads (cons p f.reads))
                (when p.per-client?
                  (set! f.per-client? #t))
                p.value)))
          ;; From scratch: nothing is kept or reused.
          (parameterize ((current-memo-frame (new-frame pass)))
            (draw inputs)))))))

(def last-pass-number 0)

(def (new-pass (cache :? memo-cache) (client : :t)) => memo-pass
  (set! last-pass-number (fx1+ last-pass-number))
  (memo-pass cache: cache client: client number: last-pass-number marked: (make-hash-table-eq)
             keys: (and checking? (make-hash-table))))

(def (run-pass (pass : memo-pass) (draw : :procedure)) => :t
  (parameterize ((current-memo-frame (new-frame pass)))
    (draw)))

;; P is no longer used by one more client; forget it when no client uses it.
(def (release! (cache : memo-cache) (p : piece)) => :void
  (set! p.users (fx1- p.users))
  (when (fxzero? p.users)
    (let (rest (remq p (hash-ref cache.pieces p.key [])))
      (if (null? rest)
        (hash-remove! cache.pieces p.key)
        (hash-put! cache.pieces p.key rest)))))

;; PASS completed: the pieces it used are its client's now; keep the new
;; ones and forget those no client uses any more.
(def (commit! (cache : memo-cache) (pass : memo-pass)) => :void
  (let ((old (hash-get cache.clients pass.client))
        (new pass.marked))
    (hash-for-each (lambda ((p : piece) _)
                     (unless (and old (hash-key? old p))
                       (when (fxzero? p.users)
                         (hash-put! cache.pieces p.key (cons p (hash-ref cache.pieces p.key []))))
                       (set! p.users (fx1+ p.users))))
                   new)
    (when old
      (hash-for-each (lambda ((p : piece) _) (unless (hash-key? new p) (release! cache p))) old))
    (hash-put! cache.clients pass.client new)))

;; X as text, when it is a string or UTF-8 bytes: a u8vector, or a vector
;; of such values read in order; otherwise #f.
(def (drawing-text (x : :t)) => (Maybe :string)
  (cond
   ((string? x) x)
   ((u8vector? x) (utf8->string x))
   ((vector? x)
    (let (parts (map drawing-text (vector->list x)))
      (and (andmap identity parts) (apply string-append parts))))
   (else #f)))

;; Where A and B, two drawings that should be the same, first differ.
(def (difference (a : :t) (b : :t)) => :string
  (let ((a (drawing-text a))
        (b (drawing-text b)))
    (if (and a b)
      (let* ((size (fxmin (string-length a) (string-length b)))
             (at (let lp ((i 0))
                   (if (and (fx< i size) (char=? (string-ref a i) (string-ref b i))) (lp (fx1+ i)) i)))
             (around (lambda ((s : :string))
                       (substring s (fxmax 0 (fx- at 80)) (fxmin (string-length s) (fx+ at 80))))))
        (string-append "at " (number->string at) ":\n  kept:    " (around a) "\n  scratch: " (around b)))
      "(not text)")))

;; Draw (DRAW) for CLIENT (#f for none) through CACHE: every memo inside
;; it keeps and reuses CACHE's pieces. Returns what DRAW returns. In test
;; mode, draws again from scratch and fails unless the two are equal?.
(def (call-with-memo-pass (cache : memo-cache) (client : :t) (draw : :procedure)) => :t
  (when (current-memo-frame)
    (error "A memo pass cannot run inside another"))
  (let* ((pass (new-pass cache client))
         (value (run-pass pass draw)))
    (commit! cache pass)
    (when checking?
      (let (fresh (run-pass (new-pass #f client) draw))
        (unless (equal? value fresh)
          (error (string-append "Drawing through memo differs from drawing from scratch " (difference value fresh))))))
    value))

;; Forget what CLIENT's last pass used.
(def (memo-forget-client! (cache : memo-cache) (client : :t)) => :void
  (let (old (hash-get cache.clients client))
    (when old
      (hash-remove! cache.clients client)
      (hash-for-each (lambda ((p : piece) _) (release! cache p)) old))))
