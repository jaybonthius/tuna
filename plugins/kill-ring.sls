#!tuna
(import (document) (buffers))

(define-option max 120
  (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How many entries the ring keeps; pushing one more drops the oldest.")

(define-option skip-duplicates #f boolean?
  "When true, pushing an entry whose text equals the newest entry's only moves the yank pointer to the newest.")

(define-hook after-push
  "Called with the newest entry after each push!, append! and prepend!.")

(define-table yankers
  "Maps a node kind's name to a procedure of a buffer, a position and a piece that yanks a piece whose top node has that kind, returning the position after what it inserted.")

(module %internals
  (check-main-thread check-entry check-piece make-buffer-piece piece-record? entry-text
   current-entry ring-entries push-entry! add-to-newest! rotate-ring! join-pieces insert-piece!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  ;; Fixed uids, so a piece made before this module reloads is still a
  ;; piece after. Joining two kills keeps both slices as parts, since
  ;; document:replace cannot join slices whose open edges differ.
  (define-record-type (piece-record make-piece-record piece-record?)
    (nongenerative kill-ring:piece/parts)
    (sealed #t)
    (fields parts))

  (define-record-type slice-part
    (nongenerative kill-ring:slice-part/slice/spans)
    (sealed #t)
    (fields slice spans))

  (define (piece-or-string? v) (or (string? v) (piece-record? v)))

  (define (check-entry who entry)
    (unless (and (pair? entry) (list? entry) (for-all piece-or-string? entry))
      (assertion-violation who "not a non-empty list of strings and pieces" entry)))

  (define (check-piece who piece)
    (unless (piece-or-string? piece)
      (assertion-violation who "not a string or a piece" piece)))

  (define (make-buffer-piece buffer start end)
    (make-piece-record
      (list (make-slice-part (document:slice (buffers:document buffer) start end)
                             (buffers:travelling-spans buffer start end)))))

  (define (parts piece)
    (if (string? piece) (list piece) (piece-record-parts piece)))

  (define (part-text part)
    (if (string? part) part (document:text (slice-part-slice part))))

  (define (part-length part)
    (if (string? part)
        (string-length part)
        (let ([doc (slice-part-slice part)])
          (document:offset doc (document:length doc) (document:unit characters)))))

  (define (piece-text piece)
    (if (string? piece) piece (apply string-append (map part-text (piece-record-parts piece)))))

  (define (piece-length piece)
    (if (string? piece)
        (string-length piece)
        (fold-left (lambda (n part) (+ n (part-length part))) 0 (piece-record-parts piece))))

  (define (entry-length entry)
    (fold-left (lambda (n piece) (+ n 1 (piece-length piece))) -1 entry))

  (define (entry-text entry)
    (let loop ([pieces (cdr entry)] [acc (list (piece-text (car entry)))])
      (if (null? pieces)
          (apply string-append (reverse acc))
          (loop (cdr pieces) (cons* (piece-text (car pieces)) "\n" acc)))))

  (define (join-pieces a b)
    (if (and (string? a) (string? b))
        (string-append a b)
        (let ([x (parts a)] [y (parts b)])
          (make-piece-record
            (let ([last (car (last-pair x))])
              (if (and (string? last) (string? (car y)))
                  (append (list-head x (fx- (length x) 1))
                          (cons (string-append last (car y)) (cdr y)))
                  (append x y)))))))

  ;; Large kills are left out, so writing the ring after a kill stays
  ;; cheap whatever was killed before.
  (define stored-piece-limit 4096)

  (define (stored-form entry)
    (and (for-all (lambda (piece) (<= (piece-length piece) stored-piece-limit)) entry)
         (map piece-text entry)))

  (define (stored-entries? v)
    (and (list? v)
         (for-all (lambda (e) (and (pair? e) (list? e) (for-all string? e))) v)))

  (define-saved texts '() stored-entries?)

  ;; One value, replaced whole, so another thread reading the ring sees
  ;; its entries and yank pointer from the same moment.
  (define-record-type ring
    (sealed #t)
    (fields slots count pointer))

  (define-record-type slot
    (sealed #t)
    (fields entry stored))

  (define state
    (let ([entries (texts)])
      (make-ring (map (lambda (e) (make-slot e e)) entries) (length entries) 0)))

  ;; Set before the ring changes, so a quit landing between the two
  ;; leaves at worst one needless save.
  (define changed? #f)

  (define (save!)
    (when changed?
      (set-saved! texts
        (fold-right (lambda (s acc) (if (slot-stored s) (cons (slot-stored s) acc) acc))
                    '() (ring-slots state)))
      (set! changed? #f)))

  (define (current-entry)
    (let ([s state])
      (and (pair? (ring-slots s))
           (slot-entry (list-ref (ring-slots s) (ring-pointer s))))))

  (define (ring-entries) (map slot-entry (ring-slots state)))

  ;; A piece's text costs its length to build, so a kill of a large range
  ;; builds no text unless the newest entry is as long.
  (define (same-text? entry newest)
    (and (= (entry-length entry) (entry-length (slot-entry newest)))
         (string=? (entry-text entry) (entry-text (or (slot-stored newest) (slot-entry newest))))))

  (define (push-entry! entry)
    (let* ([s state] [slots (ring-slots s)])
      (if (and (pair? slots) (skip-duplicates) (same-text? entry (car slots)))
          (begin
            (set! state (make-ring slots (ring-count s) 0))
            (after-push (slot-entry (car slots))))
          (let ([limit (max)] [slots (cons (make-slot entry (stored-form entry)) slots)]
                [n (+ (ring-count s) 1)])
            (set! changed? #t)
            (set! state (if (> n limit)
                            (make-ring (list-head slots limit) limit 0)
                            (make-ring slots n 0)))
            (after-push entry)))))

  (define (add-to-newest! entry join)
    (let* ([s state] [slots (ring-slots s)])
      (if (and (pair? slots) (fx= (length (slot-entry (car slots))) (length entry)))
          (let ([joined (map join (slot-entry (car slots)) entry)])
            (set! changed? #t)
            (set! state (make-ring (cons (make-slot joined (stored-form joined)) (cdr slots))
                                   (ring-count s) 0))
            (after-push joined))
          (push-entry! entry))))

  (define (rotate-ring! who n)
    (let ([s state])
      (when (null? (ring-slots s))
        (assertion-violation who "the kill ring is empty"))
      (let ([pointer (mod (+ (ring-pointer s) n) (ring-count s))])
        (set! state (make-ring (ring-slots s) (ring-count s) pointer))
        (slot-entry (list-ref (ring-slots s) pointer)))))

  ;; Only a piece that starts with a node's opening, or an atom, holding
  ;; the rest of it has a top node: one that starts inside a node holds
  ;; part of that node's content, not the node.
  (define (top-kind piece)
    (let ([x (piece-record-parts piece)])
      (and (null? (cdr x))
           (slice-part? (car x))
           (let ([doc (slice-part-slice (car x))])
             (and (fx= (document:open-start doc) 0)
                  (fx> (document:length doc) 0)
                  (let ([t (document:token doc 0)])
                    (and (document:node? t)
                         (fx= (document:node-end t) (document:length doc))
                         (document:node-kind t))))))))

  (define (replace-at! buffer position content spans)
    (let ([edit (if spans
                    (buffers:replace! buffer position position content spans)
                    (buffers:replace! buffer position position content))])
      (+ position
         (- (document:length (buffers:edit-inserted edit))
            (document:length (buffers:edit-removed edit))))))

  (define (insert-part! buffer position part)
    (if (string? part)
        (replace-at! buffer position part #f)
        (replace-at! buffer position (slice-part-slice part) (slice-part-spans part))))

  (define (insert-piece! buffer position piece)
    (cond
      [(string? piece) (replace-at! buffer position piece #f)]
      [(let ([kind (top-kind piece)]) (and kind (table-ref yankers kind #f)))
       => (lambda (yank) (yank buffer position piece))]
      [(null? (cdr (piece-record-parts piece)))
       (insert-part! buffer position (car (piece-record-parts piece)))]
      [else
       (let ([version (buffers:version buffer)])
         (guard (c [#t (restore! buffer version) (raise c)])
           (fold-left (lambda (at part) (insert-part! buffer at part))
             position (piece-record-parts piece))))]))

  ;; Each part is its own edit, so a part refused after others went in
  ;; would leave half a yank. Every edit since, after-edit hooks' too, is
  ;; taken back with splice!, which asks no kind that could refuse.
  (define (restore! buffer version)
    (for-each
      (lambda (e)
        (let ([start (buffers:edit-start e)])
          (let-values ([(removed-spans inserted-spans) (buffers:edit-spans e)])
            (buffers:splice! buffer start (+ start (document:length (buffers:edit-inserted e)))
              (buffers:edit-removed e) removed-spans))))
      (reverse (buffers:edits-since buffer version))))

  (advice-add! batch-ended
    (lambda (ended)
      (save!)
      (ended)))

  (on-unload save!)

  (record-writer (record-type-descriptor piece-record)
    (lambda (p port wr) (display "#<piece>" port))))

(import %internals)

(define (piece buffer start end)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'kill-ring:piece "not a buffer" buffer))
  (check-main-thread 'kill-ring:piece)
  (let ([size (document:length (buffers:document buffer))])
    (unless (and (integer? start) (exact? start) (integer? end) (exact? end) (<= 0 start end size))
      (assertion-violation 'kill-ring:piece "not a range of the buffer" start end)))
  (make-buffer-piece buffer start end))

(define (piece? v) (piece-record? v))

(define (push! entry)
  (check-main-thread 'kill-ring:push!)
  (check-entry 'kill-ring:push! entry)
  (push-entry! entry))

(define (append! entry)
  (check-main-thread 'kill-ring:append!)
  (check-entry 'kill-ring:append! entry)
  (add-to-newest! entry join-pieces))

(define (prepend! entry)
  (check-main-thread 'kill-ring:prepend!)
  (check-entry 'kill-ring:prepend! entry)
  (add-to-newest! entry (lambda (newest piece) (join-pieces piece newest))))

(define (current) (current-entry))

(define (rotate! n)
  (check-main-thread 'kill-ring:rotate!)
  (unless (and (integer? n) (exact? n))
    (assertion-violation 'kill-ring:rotate! "not an exact integer" n))
  (rotate-ring! 'kill-ring:rotate! n))

(define (entries) (ring-entries))

(define (text entry)
  (check-entry 'kill-ring:text entry)
  (entry-text entry))

(define (insert! buffer position piece)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'kill-ring:insert! "not a buffer" buffer))
  (unless (and (integer? position) (exact? position) (>= position 0))
    (assertion-violation 'kill-ring:insert! "not a position" position))
  (check-piece 'kill-ring:insert! piece)
  (check-main-thread 'kill-ring:insert!)
  (unless (<= position (document:length (buffers:document buffer)))
    (assertion-violation 'kill-ring:insert! "not a position in the buffer" position))
  (insert-piece! buffer position piece))
