#!tuna
(import (document) (buffers) (hooks) (options) (tables) (saved))

(options:define-option max 120
  (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How many entries the ring keeps; pushing one more drops the oldest.")

(options:define-option skip-duplicates #f boolean?
  "When true, pushing an entry whose text equals the newest entry's only moves the yank pointer to the newest.")

(hooks:define-hook after-push
  "Called with the newest entry after each push!, append! and prepend!.")

(tables:define-table yankers
  "Maps a node kind's name to a procedure of a buffer, a position and a buffers:piece that yanks a piece whose top node has that kind, returning the position after what it inserted.")

(module %internals
  (check-main-thread check-entry check-kills check-item kill-record? to-kill entry-text
   current-entry ring-entries push-entry! add-to-newest! rotate-ring! join-kills insert-item! restore! inserted-since kill-of)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  ;; Fixed uids, so a kill made before this module reloads is still a
  ;; kill after. Joining two kills keeps both pieces as parts, since
  ;; document:replace cannot join slices whose open edges differ.
  (define-record-type (kill-record make-kill-record kill-record?)
    (nongenerative kill-ring:kill/parts/yank)
    (sealed #t)
    (fields parts yank))

  ;; A part keeps the text of each atom in its piece, since a kind's text
  ;; is read only on the main thread and the part's text is read on any.
  (define-record-type piece-part
    (nongenerative kill-ring:piece-part/piece/atom-texts)
    (sealed #t)
    (fields piece atom-texts))

  (define (kill? v) (or (string? v) (kill-record? v)))

  (define (item? v) (or (kill? v) (buffers:piece? v)))

  (define (check-entry who entry)
    (unless (and (pair? entry) (list? entry) (for-all item? entry))
      (assertion-violation who "not a non-empty list of strings, pieces and kills" entry)))

  (define (check-kills who entry)
    (unless (and (pair? entry) (list? entry) (for-all kill? entry))
      (assertion-violation who "not a non-empty list of strings and kills" entry)))

  (define (check-item who item)
    (unless (item? item)
      (assertion-violation who "not a string, a piece or a kill" item)))

  (define chars (document:unit characters))

  (define (to-kill item)
    (if (buffers:piece? item)
        (let ([doc (buffers:piece-document item)])
          (make-kill-record
            (list (make-piece-part item (buffers:atom-texts doc 0 (document:length doc))))
            #f))
        item))

  (define (parts kill)
    (if (string? kill) (list kill) (kill-record-parts kill)))

  (define (part-text part)
    (if (string? part)
        part
        (let ([doc (buffers:piece-document (piece-part-piece part))])
          (document:text doc 0 (document:length doc) (piece-part-atom-texts part)))))

  (define (part-length part)
    (if (string? part)
        (string-length part)
        (let ([doc (buffers:piece-document (piece-part-piece part))])
          (fold-left (lambda (n a) (+ n (string-length (cdr a)) -1))
                     (document:offset doc (document:length doc) chars)
                     (piece-part-atom-texts part)))))

  (define (kill-text kill)
    (if (string? kill) kill (apply string-append (map part-text (kill-record-parts kill)))))

  (define (kill-length kill)
    (if (string? kill)
        (string-length kill)
        (fold-left (lambda (n part) (+ n (part-length part))) 0 (kill-record-parts kill))))

  (define (entry-length entry)
    (fold-left (lambda (n kill) (+ n 1 (kill-length kill))) -1 entry))

  (define (entry-text entry)
    (let loop ([kills (cdr entry)] [acc (list (kill-text (car entry)))])
      (if (null? kills)
          (apply string-append (reverse acc))
          (loop (cdr kills) (cons* (kill-text (car kills)) "\n" acc)))))

  (define (join-kills a b)
    (if (and (string? a) (string? b))
        (string-append a b)
        (let ([x (parts a)] [y (parts b)])
          (make-kill-record
            (let ([last (car (last-pair x))])
              (if (and (string? last) (string? (car y)))
                  (append (list-head x (fx- (length x) 1))
                          (cons (string-append last (car y)) (cdr y)))
                  (append x y)))
            #f))))

  (define (kill-of items yank)
    (let ([kill (fold-left join-kills (to-kill (car items)) (map to-kill (cdr items)))])
      (make-kill-record (parts kill) yank)))

  (define (yanks-itself? kill) (and (kill-record? kill) (kill-record-yank kill) #t))

  ;; Large kills are left out, so writing the ring after a kill stays
  ;; cheap whatever was killed before. saved:set! copies every mutable
  ;; string it is given, so each text is made immutable once, at its kill.
  (define stored-kill-limit 4096)

  (define (stored-form entry)
    (and (for-all (lambda (kill) (<= (kill-length kill) stored-kill-limit)) entry)
         (map (lambda (kill) (string->immutable-string (kill-text kill))) entry)))

  (define (stored-entries? v)
    (and (list? v)
         (for-all (lambda (e) (and (pair? e) (list? e) (for-all string? e))) v)))

  (saved:define-saved texts '() stored-entries?)

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

  ;; Set before the ring changes, so a cancel landing between the two
  ;; leaves at worst one needless save.
  (define changed? #f)

  (define (save!)
    (when changed?
      (saved:set! texts
        (fold-right (lambda (s acc) (if (slot-stored s) (cons (slot-stored s) acc) acc))
                    '() (ring-slots state)))
      (set! changed? #f)))

  (define (current-entry)
    (let ([s state])
      (and (pair? (ring-slots s))
           (slot-entry (list-ref (ring-slots s) (ring-pointer s))))))

  (define (ring-entries) (map slot-entry (ring-slots state)))

  ;; A kill's text costs its length to build, so a kill of a large range
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

  ;; A kill that yanks itself is shaped whole by its procedure, which
  ;; would shape a kill joined to it too, so it is never joined, as
  ;; Emacs's rectangle kill sets kill-region-dont-append.
  (define (add-to-newest! entry join)
    (let* ([s state] [slots (ring-slots s)])
      (if (and (pair? slots) (fx= (length (slot-entry (car slots))) (length entry))
               (not (exists yanks-itself? (slot-entry (car slots))))
               (not (exists yanks-itself? entry)))
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
    (let ([doc (buffers:piece-document piece)])
      (and (fx= (document:open-start doc) 0)
           (fx> (document:length doc) 0)
           (let ([t (document:token doc 0)])
             (and (document:node? t)
                  (fx= (document:node-end t) (document:length doc))
                  (document:node-kind t))))))

  (define (insert-piece! buffer position piece)
    (let ([yank (let ([kind (top-kind piece)]) (and kind (tables:ref yankers kind #f)))])
      (if yank
          (yank buffer position piece)
          (buffers:insert! buffer position piece))))

  (define (insert-part! buffer position part)
    (if (string? part)
        (buffers:insert! buffer position part)
        (buffers:insert! buffer position (piece-part-piece part))))

  (define (insert-item! buffer position item)
    (cond
      [(string? item) (buffers:insert! buffer position item)]
      [(buffers:piece? item) (insert-piece! buffer position item)]
      [(kill-record-yank item) => (lambda (yank) (yank buffer position))]
      [(null? (cdr (kill-record-parts item)))
       (let ([part (car (kill-record-parts item))])
         (if (string? part)
             (buffers:insert! buffer position part)
             (insert-piece! buffer position (piece-part-piece part))))]
      [else
       (fold-left (lambda (at part) (insert-part! buffer at part))
         position (kill-record-parts item))]))

  ;; A kill of several parts, or one with its own yank procedure, makes
  ;; several edits, so one refused after others went in would leave half
  ;; a yank. Every edit since, after-edit hooks' too, is taken back with
  ;; splice!, which asks no kind that could refuse.
  (define (restore! buffer version)
    (for-each
      (lambda (e)
        (let ([start (buffers:edit-start e)])
          (buffers:splice! buffer start (+ start (buffers:piece-length (buffers:edit-inserted e)))
            (buffers:edit-removed e))))
      (reverse (buffers:edits-since buffer version))))

  ;; The edit log holds every insertion, whatever made it, so a yank
  ;; procedure need not account for its own, padding and added lines
  ;; included. An insertion that fitting widened removes the tokens
  ;; around the place and puts them back; the new ones are those after
  ;; that many, as buffers:insert! counts the position after. Ranges are
  ;; kept last first, and an edit moves only those that end past its
  ;; start, so a yank made from the top down, as a rectangle's is, moves
  ;; none and is read in one pass.
  (define (inserted-since buffer version)
    (define (moved p start removed inserted)
      (cond
        [(<= p start) p]
        [(< p (+ start removed)) start]
        [else (+ p (- inserted removed))]))
    ;; Joining those that meet keeps the ranges apart, so their ends are
    ;; in order too and a range that ends before an edit is the last moved.
    (define (joined ascending)
      (reverse
        (fold-left
          (lambda (acc r)
            (if (and (pair? acc) (<= (car r) (cdar acc)))
                (cons (cons (caar acc) (fxmax (cdr r) (cdar acc))) (cdr acc))
                (cons r acc)))
          '() ascending)))
    (let loop ([edits (buffers:edits-since buffer version)] [ranges '()])
      (if (null? edits)
          (filter (lambda (r) (< (car r) (cdr r))) (reverse ranges))
          (let* ([e (car edits)] [start (buffers:edit-start e)]
                 [removed (buffers:piece-length (buffers:edit-removed e))]
                 [inserted (buffers:piece-length (buffers:edit-inserted e))])
            (if (buffers:edit-moves? e)
                (let shift ([rs ranges] [moved-rs '()])
                  (if (and (pair? rs) (> (cdar rs) start))
                      (shift (cdr rs)
                             (cons (cons (moved (caar rs) start removed inserted) (moved (cdar rs) start removed inserted))
                                   moved-rs))
                      (let* ([new (if (< removed inserted) (list (cons (+ start removed) (+ start inserted))) '())]
                             [around (list-sort (lambda (x y) (< (car x) (car y))) (append new moved-rs))]
                             [around (if (pair? rs) (cons (car rs) around) around)]
                             [rest (if (pair? rs) (cdr rs) rs)])
                        (loop (cdr edits) (fold-left (lambda (acc r) (cons r acc)) rest (joined around))))))
                (loop (cdr edits) ranges))))))

  (advice-add! batch-ended
    (lambda (ended)
      (save!)
      (ended)))

  (on-unload save!)

  (record-writer (record-type-descriptor kill-record)
    (lambda (k port wr) (display "#<kill>" port))))

(import %internals)

(define (push! entry)
  (check-main-thread 'kill-ring:push!)
  (check-entry 'kill-ring:push! entry)
  (push-entry! (map to-kill entry)))

(define (append! entry)
  (check-main-thread 'kill-ring:append!)
  (check-entry 'kill-ring:append! entry)
  (add-to-newest! (map to-kill entry) join-kills))

(define (prepend! entry)
  (check-main-thread 'kill-ring:prepend!)
  (check-entry 'kill-ring:prepend! entry)
  (add-to-newest! (map to-kill entry) (lambda (newest kill) (join-kills kill newest))))

(define (join . items)
  (check-main-thread 'kill-ring:join)
  (for-each (lambda (item) (check-item 'kill-ring:join item)) items)
  (if (null? items)
      ""
      (let ([kills (map to-kill items)])
        (fold-left join-kills (car kills) (cdr kills)))))

(define (current) (current-entry))

(define (rotate! n)
  (check-main-thread 'kill-ring:rotate!)
  (unless (and (integer? n) (exact? n))
    (assertion-violation 'kill-ring:rotate! "not an exact integer" n))
  (rotate-ring! 'kill-ring:rotate! n))

(define (entries) (ring-entries))

(define (text entry)
  (check-kills 'kill-ring:text entry)
  (entry-text entry))

(define (make-kill items yank)
  (check-entry 'kill-ring:make-kill items)
  (unless (procedure? yank)
    (assertion-violation 'kill-ring:make-kill "not a procedure" yank))
  (kill-of items yank))

(define (insert! buffer position item)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'kill-ring:insert! "not a buffer" buffer))
  (unless (and (integer? position) (exact? position) (>= position 0))
    (assertion-violation 'kill-ring:insert! "not a position" position))
  (check-item 'kill-ring:insert! item)
  (check-main-thread 'kill-ring:insert!)
  (unless (<= position (document:length (buffers:document buffer)))
    (assertion-violation 'kill-ring:insert! "not a position in the buffer" position))
  (let ([version (buffers:version buffer)])
    (guard (c [#t (restore! buffer version) (raise c)])
      (insert-item! buffer position item))
    (inserted-since buffer version)))
