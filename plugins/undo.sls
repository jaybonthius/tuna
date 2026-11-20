#!tuna
(import (buffers) (document) (views) (commands) (keys) (ask))

(define-option limit 4000000 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How large a buffer's history may grow: the characters its edits removed and inserted, plus 32 per edit. 0 keeps no history.")

(module %internals
  (check-main-thread check-buffer check-count current-buffer without-quits history-of buffer-history
   state-id state-parent state-time state-cursors state-of states-by-id history? history-buffer
   history-current history-holds saved-state close-group! take-hold! release-hold! leave-hold!
   forget-escape! cancel-group! move! redo-child group-end restore-cursors! place-cursors! path-moves
   no-further amalgamate-history! record-edit! forget-history! note-command-start! note-command-end!
   end-batch! take-buffer-records! replay current-text attach-buffer! install-history!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-buffer who b)
    (unless (buffers:buffer? b)
      (assertion-violation who "not a buffer" b))
    (check-main-thread who))

  (define (check-count who n)
    (unless (and (fixnum? n) (fx> n 0))
      (assertion-violation who "not a positive count" n)))

  (define (current-buffer who)
    (check-main-thread who)
    (or (buffers:current) (assertion-violation who "no buffer is current")))

  (define (now) (time-second (current-time 'time-utc)))

  (define (no-further who what)
    (raise (condition (make-error) (make-who-condition who)
                      (make-message-condition (format "no further ~a information" what)))))

  (define-condition-type &stale &error make-stale-condition stale-condition?)

  (define (stale who)
    (raise (condition (make-stale-condition) (make-who-condition who)
                      (make-message-condition "the buffer does not hold the text its history expects"))))

  (define (warn who message irritants)
    (report (condition (make-warning) (make-who-condition who) (make-message-condition message)
                       (make-irritants-condition irritants))))

  ;; Tuna's dynamic-wind holds quits off while its in runs, so the tree,
  ;; the buffer and the records queued never part company halfway.
  (define (without-quits thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  ;; An edit's content is a piece, or a document when the edit was read
  ;; back from records, which hold no spans; buffers:splice! takes both.
  ;; Each step of undo or redo keeps the piece it takes out of the buffer
  ;; as the content to put back, as Emacs keeps deleted text with its
  ;; properties, so spans set silently since the edit was made come back
  ;; with redo.
  (define-record-type edit
    (sealed #t)
    (fields (mutable start) (mutable removed) (mutable inserted)))

  (define (content-length c)
    (if (buffers:piece? c) (buffers:piece-length c) (document:length c)))

  (define (content-document c)
    (if (buffers:piece? c) (buffers:piece-document c) c))

  (define-record-type state
    (sealed #t)
    (fields id (mutable parent) (mutable edits-newest-first) (mutable count) (mutable time) (mutable cursors)
            (mutable children) (mutable left) (mutable length) (mutable size)
            (mutable command) (mutable run) (mutable joins) (mutable written-count) (mutable queued?)))

  (define-record-type history
    (sealed #t)
    (fields states (mutable buffer) (mutable root) (mutable current) (mutable stamped) (mutable stamp)
            (mutable next-id) (mutable size) (mutable open) (mutable holds) (mutable join)
            (mutable recorded-version) (mutable taken?) (mutable whole?) (mutable pending)
            (mutable dirty?)))

  (define (new-history id length time)
    (let ([root (make-state id #f '() 0 time '() '() #f length 0 #f #f 0 0 #f)]
          [h (make-history (make-eqv-hashtable) #f #f #f #f #f (fx+ id 1) 0 #f '() #f 0 #f #f '() #f)])
      (hashtable-set! (history-states h) id root)
      (history-root-set! h root)
      (history-current-set! h root)
      h))

  (define (take-whole! h)
    (history-whole?-set! h #t))

  (define (state-of h id) (hashtable-ref (history-states h) id #f))

  (define (live? h s) (eq? (state-of h (state-id s)) s))

  (define (states-by-id h)
    (list-sort (lambda (a b) (fx< (state-id a) (state-id b)))
               (vector->list (hashtable-values (history-states h)))))

  (define (add-state! h id parent cursors time)
    (let ([s (make-state id parent '() 0 time cursors '() #f (state-length parent) 0 #f #f 1 #f #f)])
      (history-next-id-set! h (fxmax (history-next-id h) (fx+ id 1)))
      (hashtable-set! (history-states h) id s)
      (state-children-set! parent (cons s (state-children parent)))
      s))

  (define (edit-delta e)
    (fx- (content-length (edit-inserted e)) (content-length (edit-removed e))))

  (define (edit-size e)
    (fx+ 32 (fx+ (content-length (edit-removed e)) (content-length (edit-inserted e)))))

  (define (push-edit! h s e)
    (let ([size (edit-size e)])
      (state-edits-newest-first-set! s (cons e (state-edits-newest-first s)))
      (state-count-set! s (fx+ (state-count s) 1))
      (state-length-set! s (fx+ (state-length s) (edit-delta e)))
      (state-size-set! s (fx+ (state-size s) size))
      (history-size-set! h (+ (history-size h) size))))

  (define (drop-newest-edits! h s n)
    (let loop ([k n])
      (unless (fx= k 0)
        (let* ([e (car (state-edits-newest-first s))] [size (edit-size e)])
          (state-edits-newest-first-set! s (cdr (state-edits-newest-first s)))
          (state-count-set! s (fx- (state-count s) 1))
          (state-length-set! s (fx- (state-length s) (edit-delta e)))
          (state-size-set! s (fx- (state-size s) size))
          (history-size-set! h (- (history-size h) size))
          (loop (fx- k 1))))))

  (define (edits-fit? length edits)
    (let loop ([n length] [es edits])
      (or (null? es)
          (let ([e (car es)])
            (and (fx<= (fx+ (edit-start e) (content-length (edit-removed e))) n)
                 (loop (fx+ n (edit-delta e)) (cdr es)))))))

  (define (drop-subtree! h s)
    (for-each (lambda (k) (drop-subtree! h k)) (state-children s))
    (history-size-set! h (- (history-size h) (state-size s)))
    (hashtable-delete! (history-states h) (state-id s)))

  (define (forget-dead-stamp! h)
    (let ([s (history-stamped h)])
      (when (and s (not (live? h s)))
        (history-stamped-set! h #f))))

  (define (prune! h s)
    (let ([p (state-parent s)])
      (state-children-set! p (remq s (state-children p)))
      (when (eq? (state-left p) s) (state-left-set! p #f))
      (drop-subtree! h s)
      (forget-dead-stamp! h)))

  (define (re-root! h s)
    (let loop ([c s])
      (let ([p (state-parent c)])
        (when p
          (for-each (lambda (k) (unless (eq? k c) (drop-subtree! h k))) (state-children p))
          (history-size-set! h (- (history-size h) (state-size p)))
          (hashtable-delete! (history-states h) (state-id p))
          (loop p))))
    (history-size-set! h (- (history-size h) (state-size s)))
    (state-parent-set! s #f)
    (state-edits-newest-first-set! s '())
    (state-count-set! s 0)
    (state-size-set! s 0)
    (history-root-set! h s)
    (forget-dead-stamp! h))

  ;; Records taken cannot be split by records taken later, so the next
  ;; take is whole.
  (define (split-state! h s kept)
    (let* ([edits (state-edits-newest-first s)] [p (state-parent s)]
           [m (add-state! h (history-next-id h) p (state-cursors s) (state-time s))])
      (state-children-set! p (remq s (state-children p)))
      (state-children-set! m (list s))
      (state-left-set! m s)
      (state-parent-set! s m)
      (history-size-set! h (- (history-size h) (state-size s)))
      (state-edits-newest-first-set! s '())
      (state-count-set! s 0)
      (state-size-set! s 0)
      (for-each (lambda (e) (push-edit! h m e)) (reverse (list-tail edits kept)))
      (state-length-set! s (state-length m))
      (for-each (lambda (e) (push-edit! h s e)) (reverse (list-head edits kept)))
      (take-whole! h)
      m))

  (define (descends? s ancestor)
    (let loop ([s s])
      (and s (or (eq? s ancestor) (loop (state-parent s))))))

  (define (vector-edit v)
    (and (vector? v) (fx= (vector-length v) 3)
         (let ([start (vector-ref v 0)] [removed (vector-ref v 1)] [inserted (vector-ref v 2)])
           (and (fixnum? start) (fx>= start 0) (document? removed) (document? inserted)
                (make-edit start removed inserted)))))

  (define (vector-edits vs)
    (and (list? vs)
         (let loop ([vs vs] [acc '()])
           (if (null? vs)
               (reverse acc)
               (let ([e (vector-edit (car vs))])
                 (and e (loop (cdr vs) (cons e acc))))))))

  (define (count? v) (and (fixnum? v) (fx>= v 0)))

  ;; Replaying records stops at the first that does not fit the history,
  ;; as at a record cut short.
  (define (apply-record! h r)
    (and (pair? r) (list? r)
         (case (car r)
           [(group)
            (and (fx>= (length r) 5)
                 (let ([id (list-ref r 1)] [p (state-of h (list-ref r 2))] [time (list-ref r 3)]
                       [cursors (list-ref r 4)] [edits (vector-edits (list-tail r 5))])
                   (and p edits (count? id) (not (state-of h id)) (fixnum? time)
                        (list? cursors) (for-all count? cursors) (edits-fit? (state-length p) edits)
                        (let ([s (add-state! h id p cursors time)])
                          (for-each (lambda (e) (push-edit! h s e)) edits)
                          (state-written-count-set! s (state-count s))
                          (history-current-set! h s)
                          #t))))]
           [(more)
            (and (fx>= (length r) 2)
                 (let ([s (state-of h (cadr r))] [edits (vector-edits (cddr r))])
                   (and s edits (state-parent s) (null? (state-children s)) (edits-fit? (state-length s) edits)
                        (begin
                          (for-each (lambda (e) (push-edit! h s e)) edits)
                          (state-written-count-set! s (state-count s))
                          #t))))]
           [(at)
            (let ([s (and (fx= (length r) 2) (state-of h (cadr r)))])
              (and s (begin (history-current-set! h s) #t)))]
           [(root)
            (let ([s (and (fx= (length r) 2) (state-of h (cadr r)))])
              (and s (descends? (history-current h) s) (begin (re-root! h s) #t)))]
           [(prune)
            (let ([s (and (fx= (length r) 2) (state-of h (cadr r)))])
              (and s (state-parent s) (not (descends? (history-current h) s)) (begin (prune! h s) #t)))]
           [else #f])))

  (define (header? r)
    (and (list? r) (fx= (length r) 5) (eq? (car r) 'undo-history) (eqv? (cadr r) 1)
         (count? (caddr r)) (count? (cadddr r)) (fixnum? (list-ref r 4))))

  (define (replay records)
    (if (or (null? records) (not (header? (car records))))
        (values #f (null? records))
        (let* ([header (car records)]
               [h (new-history (list-ref header 2) (list-ref header 3) (list-ref header 4))])
          (state-written-count-set! (history-root h) 0)
          (history-taken?-set! h #t)
          (let loop ([rs (cdr records)])
            (cond
              [(null? rs) (values h #t)]
              [(apply-record! h (car rs)) (loop (cdr rs))]
              [else (values h #f)])))))

  (define (edit-vector e)
    (vector (edit-start e) (content-document (edit-removed e)) (content-document (edit-inserted e))))

  (define (group-record s)
    (cons* 'group (state-id s) (state-id (state-parent s)) (state-time s) (state-cursors s)
           (map edit-vector (reverse (state-edits-newest-first s)))))

  ;; Records follow the tree, not ids: a state split from a group is its
  ;; parent with a newer id. Children go oldest first, so a replay, which
  ;; adds each child in front of its siblings, rebuilds them in order.
  (define (history-records h)
    (let ([root (history-root h)])
      (let loop ([stack (reverse (state-children root))] [groups '()])
        (if (null? stack)
            (append
              (list (list 'undo-history 1 (state-id root) (state-length root) (state-time root)))
              (reverse groups)
              (list (list 'at (state-id (history-current h)))))
            (let ([s (car stack)])
              (loop (append (reverse (state-children s)) (cdr stack)) (cons (group-record s) groups)))))))

  (define (mark-written! h)
    (vector-for-each
      (lambda (s) (state-written-count-set! s (state-count s)) (state-queued?-set! s #f))
      (hashtable-values (history-states h))))

  ;; Nothing is queued until the records are first taken, so a history
  ;; whose records nobody takes keeps no list of changes.
  (define (queue! h item)
    (when (history-taken? h)
      (history-pending-set! h (cons item (history-pending h)))))

  (define (queue-group! h s)
    (unless (state-queued? s)
      (state-queued?-set! s #t)
      (queue! h (list 'group s))))

  ;; An item naming a state whose group record was never taken leaves
  ;; nothing, as a group undone before its batch ended.
  (define (pending-records h)
    (let loop ([items (reverse (history-pending h))] [acc '()])
      (if (null? items)
          (reverse acc)
          (let* ([item (car items)] [kind (car item)] [s (cadr item)])
            (define (next record) (loop (cdr items) (if record (cons record acc) acc)))
            (case kind
              [(group)
               (state-queued?-set! s #f)
               (let ([written (state-written-count s)] [count (state-count s)])
                 (cond
                   [(not (live? h s)) (next #f)]
                   [(not written)
                    (state-written-count-set! s count)
                    (next (group-record s))]
                   [(fx> count written)
                    (state-written-count-set! s count)
                    (next (cons* 'more (state-id s)
                                 (map edit-vector
                                      (reverse (list-head (state-edits-newest-first s) (fx- count written))))))]
                   [else (next #f)]))]
              [(prune) (next (and (state-written-count s) (list 'prune (state-id s))))]
              [else (next (and (live? h s) (state-written-count s) (list kind (state-id s))))])))))

  (define (take-buffer-records! b whole?)
    (without-quits
      (lambda ()
        (let ([h (buffer-history b)])
          (and h
               (begin
                 (catch-up! h)
                 (let ([h (buffer-history b)])
                   (and h (take! h whole?)))))))))

  (define (take! h whole?)
    (if (or whole? (not (history-taken? h)) (history-whole? h))
        (begin
          (history-taken?-set! h #t)
          (history-whole?-set! h #f)
          (history-pending-set! h '())
          (mark-written! h)
          (history-records h))
        (let ([records (pending-records h)])
          (history-pending-set! h '())
          records)))

  (define histories (make-weak-eq-hashtable))

  (define attaching (make-weak-eq-hashtable))

  (define dirty '())

  (define (mark-dirty! h)
    (unless (history-dirty? h)
      (history-dirty?-set! h #t)
      (set! dirty (cons h dirty))))

  (define (buffer-history b) (eq-hashtable-ref histories b #f))

  (define (installed? h)
    (let ([b (history-buffer h)])
      (and b (eq? (eq-hashtable-ref histories b #f) h))))

  (define (close-group! h)
    (without-quits
      (lambda ()
        (catch-up! h)
        (let ([o (history-open h)])
          (when (and o (null? (history-holds h)))
            (state-time-set! o (now))
            (history-open-set! h #f)))
        (history-join-set! h #f))))

  (define-record-type hold
    (sealed #t)
    (fields history task open edits))

  (define (take-hold! h)
    (without-quits
      (lambda ()
        (when (null? (history-holds h)) (close-group! h))
        (let* ([o (history-open h)]
               [hold (make-hold h (current-task) o (if o (state-edits-newest-first o) '()))])
          (history-holds-set! h (cons hold (history-holds h)))
          hold))))

  (define (release-hold! hold)
    (without-quits
      (lambda ()
        (let ([h (hold-history hold)])
          (when (memq hold (history-holds h))
            (history-holds-set! h (remq hold (history-holds h)))
            (when (null? (history-holds h))
              (close-group! h)
              (mark-dirty! h)))))))

  ;; dynamic-wind's out runs when a task pauses as when a continuation
  ;; escapes, and only a pause comes back. So a hold left outside its body
  ;; is released once its task is seen running elsewhere or ended.
  (define escaped '())

  (define (leave-hold! hold)
    (when (memq hold (history-holds (hold-history hold)))
      (if (hold-task hold)
          (set! escaped (cons hold escaped))
          (release-hold! hold))))

  (define (forget-escape! hold)
    (set! escaped (remq hold escaped)))

  (define (release-escaped!)
    (unless (null? escaped)
      (let ([task (current-task)])
        (for-each
          (lambda (hold)
            (when (or (eq? (hold-task hold) task) (task-done? (hold-task hold)))
              (forget-escape! hold)
              (release-hold! hold)))
          escaped))))

  (define (limit-of b) (buffers:with-buffer b (limit)))

  (define (begin-history! b length version)
    (let ([h (new-history 0 length (now))])
      (history-buffer-set! h b)
      (history-recorded-version-set! h version)
      (eq-hashtable-set! histories b h)
      h))

  (define (history-of who b)
    (or (eq-hashtable-ref histories b #f)
        (let ([waiting (eq-hashtable-ref attaching b #f)])
          (cond
            [(not waiting)
             (begin-history! b (document:length (buffers:document b)) (buffers:version b))]
            [(current-task)
             (suspend (lambda (resume) (set-box! waiting (cons resume (unbox waiting)))))
             (history-of who b)]
            [else
             (raise (condition (make-error) (make-who-condition who)
                               (make-message-condition "the buffer's history is still being read")
                               (make-irritants-condition (list b))))]))))

  ;; Undo puts the cursors back where the command that made the group
  ;; found them, which its edits cannot tell: a deletion forward and one
  ;; backward leave the same edit. So each command's cursors are noted as
  ;; it starts; a group made outside a command maps the cursors back
  ;; through its first edit.
  (define run 0)
  (define command-buffer #f)
  (define command-points '())

  (define (cursor-points v) (map views:cursor-point (views:cursors v)))

  (define (note-command-start! command)
    (let* ([v (views:current)] [b (and v (views:buffer v))] [points (if b (cursor-points v) '())])
      (without-quits
        (lambda ()
          (release-escaped!)
          (set! run (fx+ run 1))
          (set! command-buffer b)
          (set! command-points points)))))

  (define (point-before p e)
    (let* ([start (edit-start e)] [end (fx+ start (content-length (edit-inserted e)))])
      (cond
        [(fx<= p start) p]
        [(fx>= p end) (fx+ (fx- p end) (fx+ start (content-length (edit-removed e))))]
        [else start])))

  (define (cursors-before b e)
    (if (and command-buffer (eq? command-buffer b) (commands:this-command))
        command-points
        (let ([v (views:current)])
          (if (and v (eq? (views:buffer v) b))
              (map (lambda (p) (point-before p e)) (cursor-points v))
              '()))))

  (define (saved-state h)
    (let ([b (history-buffer h)])
      (cond
        [(not (buffers:modified? b)) (history-current h)]
        [(eqv? (history-stamp h) (buffers:save-stamp b)) (history-stamped h)]
        [else #f])))

  (define (stamp! h b)
    (history-stamped-set! h (history-current h))
    (history-stamp-set! h (buffers:save-stamp b)))

  (define (joins? h s command)
    (and command (state-parent s) (eq? (state-command s) command)
         (eqv? (state-run s) (fx- run 1)) (fx< (state-joins s) 20)
         (not (eq? s (saved-state h)))))

  ;; A group still open when the buffer was marked unmodified goes on to
  ;; hold text the mark never saw, so it is not stamped.
  (define (add-edit! h b e version)
    (when (and (eqv? (buffers:save-stamp b) (fx- version 1))
               (not (eq? (history-open h) (history-current h))))
      (stamp! h b))
    (let ([o (history-open h)] [c (history-current h)] [command (commands:this-command)])
      (cond
        [(and o (eq? o c))
         (push-edit! h o e)
         (queue-group! h o)]
        [(and (eqv? (history-join h) run) (joins? h c command) (null? (state-children c)))
         (state-joins-set! c (fx+ (state-joins c) 1))
         (state-run-set! c run)
         (history-open-set! h c)
         (history-join-set! h #f)
         (push-edit! h c e)
         (queue-group! h c)]
        [else
         (let ([s (add-state! h (history-next-id h) c (cursors-before b e) (now))])
           (state-command-set! s command)
           (state-run-set! s (and command run))
           (history-open-set! h s)
           (history-current-set! h s)
           (push-edit! h s e)
           (queue-group! h s))])
      (mark-dirty! h)))

  (define (edit-of e)
    (make-edit (buffers:edit-start e) (buffers:edit-removed e) (buffers:edit-inserted e)))

  (define (map-point p start removed inserted)
    (cond
      [(fx< p start) p]
      [(fx>= p (fx+ start removed)) (fx+ p (fx- inserted removed))]
      [else start]))

  (define (map-cursors! x start removed inserted)
    (unless (null? (state-cursors x))
      (state-cursors-set! x (map (lambda (p) (map-point p start removed inserted)) (state-cursors x)))))

  (define (drop-edits! h x dropped)
    (for-each
      (lambda (e)
        (state-count-set! x (fx- (state-count x) 1))
        (state-size-set! x (fx- (state-size x) (edit-size e)))
        (history-size-set! h (- (history-size h) (edit-size e))))
      dropped)
    (state-edits-newest-first-set! x (remp (lambda (e) (memq e dropped)) (state-edits-newest-first x))))

  ;; An edit inside the text a silent edit removes goes with it, since no
  ;; later state holds that text to undo.
  (define (carry! h x start removed inserted back?)
    (let loop ([es (if back? (state-edits-newest-first x) (reverse (state-edits-newest-first x)))]
               [start start] [removed removed] [dropped '()])
      (if (null? es)
          (begin
            (unless (null? dropped) (drop-edits! h x dropped))
            (values start removed))
          (let* ([e (car es)] [at (edit-start e)]
                 [near (content-length (if back? (edit-inserted e) (edit-removed e)))]
                 [far (content-length (if back? (edit-removed e) (edit-inserted e)))])
            (cond
              [(fx<= (fx+ start removed) at)
               (edit-start-set! e (fx+ at (fx- inserted removed)))
               (loop (cdr es) start removed dropped)]
              [(fx>= start (fx+ at near)) (loop (cdr es) (fx+ start (fx- far near)) removed dropped)]
              [(and (fx<= start at) (fx<= (fx+ at near) (fx+ start removed)))
               (loop (cdr es) start (fx+ (fx- removed near) far) (cons e dropped))]
              [else (values #f #f)])))))

  ;; A group left with no edits is no step of undo, so its children
  ;; become its parent's.
  (define (splice-out! h x)
    (let ([p (state-parent x)] [children (state-children x)])
      (for-each (lambda (k) (state-parent-set! k p)) children)
      (state-children-set! p (fold-right (lambda (k acc) (if (eq? k x) (append children acc) (cons k acc)))
                                         '() (state-children p)))
      (when (eq? (state-left p) x) (state-left-set! p (redo-child x)))
      (when (eq? (history-current h) x) (history-current-set! h p))
      (when (eq? (history-open h) x) (history-open-set! h #f))
      (when (eq? (history-stamped h) x) (history-stamped-set! h p))
      (hashtable-delete! (history-states h) (state-id x))))

  (define (emptied? x) (and (state-parent x) (fx= (state-count x) 0)))

  (define (map-branch! h x start removed inserted)
    (map-cursors! x start removed inserted)
    (let-values ([(start removed*) (carry! h x start removed inserted #f)])
      (if start
          (begin
            (state-length-set! x (fx+ (state-length x) (fx- inserted removed*)))
            (for-each (lambda (k) (map-branch! h k start removed* inserted)) (state-children x))
            (when (emptied? x) (splice-out! h x)))
          (prune! h x))))

  ;; A silent edit is not history, yet every state's text holds the text
  ;; it changed. A group whose edits it cuts into cannot be undone past
  ;; it: on the path that group's state becomes the root, and a branch is
  ;; cut there. A group made the root is closed, since undo never takes
  ;; back an edit pushed onto the root. Records already taken name the
  ;; old positions, so the next take is whole.
  (define (map-silent! h e)
    (let ([inserted (buffers:piece-length (buffers:edit-inserted e))])
      (let up ([x (history-current h)] [start (buffers:edit-start e)]
               [removed (buffers:piece-length (buffers:edit-removed e))] [from #f] [emptied '()])
        (state-length-set! x (fx+ (state-length x) (fx- inserted removed)))
        (for-each (lambda (k) (unless (eq? k from) (map-branch! h k start removed inserted))) (state-children x))
        (if (state-parent x)
            (let-values ([(before removed*) (carry! h x start removed inserted #t)])
              (cond
                [before
                 (map-cursors! x before removed* inserted)
                 (up (state-parent x) before removed* x (if (emptied? x) (cons x emptied) emptied))]
                [else
                 (re-root! h x)
                 (when (eq? (history-open h) x) (history-open-set! h #f))
                 (for-each (lambda (x) (splice-out! h x)) emptied)]))
            (for-each (lambda (x) (splice-out! h x)) emptied)))
      (take-whole! h)))

  (define (note-edit-of! h b e version)
    (if (buffers:edit-silent? e)
        (when (buffers:edit-moves? e) (map-silent! h e))
        (add-edit! h b (edit-of e) version)))

  (define applying #f)

  (define (record-edit! b e)
    (without-quits (lambda () (note-edit! b e))))

  (define (note-edit! b e)
    (unless (eq? b applying)
      (let ([h (eq-hashtable-ref histories b #f)])
        (cond
          [(and (not h) (buffers:edit-silent? e)) (void)]
          [(eqv? (limit) 0) (when h (drop! h))]
          [(eq-hashtable-contains? attaching b) (void)]
          [else
           (let ([version (buffers:edit-version e)]
                 [h (or h (begin-history! b (fx- (document:length (buffers:document b))
                                                 (fx- (buffers:piece-length (buffers:edit-inserted e))
                                                      (buffers:piece-length (buffers:edit-removed e))))
                                          (fx- (buffers:edit-version e) 1)))])
             (if (fx= version (fx+ (history-recorded-version h) 1))
                 (begin
                   (note-edit-of! h b e version)
                   (history-recorded-version-set! h version))
                 (catch-up! h)))]))))

  (define (add-edits! h b edits)
    (for-each (lambda (e) (note-edit-of! h b e (buffers:edit-version e))) edits))

  ;; A quit that lands as the buffer calls its after-edit entries, before
  ;; this module's starts, skips the record; the buffer keeps its recent
  ;; edits, so the next edit or step of undo records what was missed.
  (define (catch-up! h)
    (let ([b (history-buffer h)])
      (when (and b (buffers:live? b) (installed? h)
                 (not (fx= (history-recorded-version h) (buffers:version b))))
        (let ([edits (buffers:edits-since b (history-recorded-version h))])
          (if edits
              (begin
                (add-edits! h b edits)
                (history-recorded-version-set! h (buffers:version b)))
              (begin
                (warn 'undo "edits were made that undo could not record, so the buffer's history starts again"
                      (list (buffers:name b)))
                (drop! h)
                (mark-dirty! (begin-history! b (document:length (buffers:document b)) (buffers:version b)))))))))

  (define (amalgamate-history! h command)
    (let ([o (history-open h)])
      (cond
        [(not o)
         (let ([c (history-current h)])
           (when (and (joins? h c command) (null? (state-children c)))
             (history-join-set! h run)))]
        [(and (eq? o (history-current h)) (eqv? (state-run o) run) (not (state-written-count o)))
         (let* ([p (state-parent o)] [children (state-children p)])
           (when (and (joins? h p command) (eq? (car children) o) (null? (cdr children)))
             (state-edits-newest-first-set! p (append (state-edits-newest-first o) (state-edits-newest-first p)))
             (state-count-set! p (fx+ (state-count p) (state-count o)))
             (state-length-set! p (state-length o))
             (state-size-set! p (fx+ (state-size p) (state-size o)))
             (state-joins-set! p (fx+ (state-joins p) 1))
             (state-run-set! p run)
             (state-children-set! p '())
             (state-left-set! p #f)
             (hashtable-delete! (history-states h) (state-id o))
             (history-open-set! h p)
             (history-current-set! h p)
             (queue-group! h p)))])))

  (define-record-type step
    (sealed #t)
    (fields edit undo?))

  (define (step-start step) (edit-start (step-edit step)))

  (define (step-out step)
    (if (step-undo? step) (edit-inserted (step-edit step)) (edit-removed (step-edit step))))

  (define (step-in step)
    (if (step-undo? step) (edit-removed (step-edit step)) (edit-inserted (step-edit step))))

  (define (undo-steps edits-newest-first)
    (map (lambda (e) (make-step e #t)) edits-newest-first))

  (define (redo-steps s)
    (map (lambda (e) (make-step e #f)) (reverse (state-edits-newest-first s))))

  (define (move-steps move)
    (if (eq? (car move) 'undo)
        (undo-steps (state-edits-newest-first (cdr move)))
        (redo-steps (cdr move))))

  (define (moves-steps moves) (apply append (map move-steps moves)))

  (define (holds? doc start expected)
    (let ([end (fx+ start (document:length expected))])
      (and (fx<= end (document:length doc))
           (or (fx= start end)
               (let ([actual (document:slice doc start end)])
                 (and (fx= (document:open-start actual) (document:open-start expected))
                      (fx= (document:open-end actual) (document:open-end expected))
                      (equal? (document:datums actual) (document:datums expected))))))))

  (define (play doc steps who)
    (fold-left
      (lambda (doc step)
        (let ([start (step-start step)] [out (content-document (step-out step))])
          (unless (holds? doc start out) (stale who))
          (guard (c [(and (assertion-violation? c) (not (quit-condition? c))) (stale who)])
            (document:replace doc start (fx+ start (document:length out)) (content-document (step-in step))))))
      doc steps))

  ;; A quit can leave the buffer's hook call after the splice is made,
  ;; though quits are held off here, so the splices made are counted by
  ;; version. Another after-edit entry's edit during a splice stops the
  ;; steps, since those after it would no longer fit.
  (define (splice-steps! h b steps)
    (let ([outer applying])
      (set! applying b)
      (let loop ([steps steps] [n 0])
        (if (null? steps)
            (begin (set! applying outer) (values #f #f '()))
            (let* ([step (car steps)] [start (step-start step)]
                   [end (fx+ start (content-length (step-out step)))]
                   [version (fx+ (buffers:version b) 1)]
                   [raised (guard (c [#t c])
                             (let ([out (buffers:edit-removed (buffers:splice! b start end (step-in step)))])
                               (if (step-undo? step)
                                   (edit-inserted-set! (step-edit step) out)
                                   (edit-removed-set! (step-edit step) out)))
                             #f)]
                   [made? (fx>= (buffers:version b) version)]
                   [n (if made? (fx+ n 1) n)])
              (when made? (history-recorded-version-set! h version))
              (if (and (not raised) (fx= (buffers:version b) version))
                  (loop (cdr steps) n)
                  (begin
                    (set! applying outer)
                    (values n raised (if made? (or (buffers:edits-since b version) '()) '())))))))))

  ;; A move cut short stops where it is: the steps spliced become a state
  ;; of their own and edits made meanwhile a group after it, so the
  ;; history still matches the buffer.
  (define (apply-moves! h b moves)
    (let loop ([moves moves])
      (if (null? moves)
          (values #t #f '() #f)
          (let* ([move (car moves)] [s (cdr move)] [undo? (eq? (car move) 'undo)] [n (state-count s)])
            (let-values ([(spliced raised others) (splice-steps! h b (move-steps move))])
              (define (reach! child)
                (state-left-set! (state-parent child) child)
                (history-current-set! h (if (and undo? (eq? child s)) (state-parent s) child)))
              (cond
                [(not spliced) (reach! s) (loop (cdr moves))]
                [else
                 (let ([split (and (fx< 0 spliced n) (split-state! h s (if undo? spliced (fx- n spliced))))])
                   (reach! (or split s))
                   (close-group! h)
                   (values (and (not raised) (fx= spliced n) (null? (cdr moves))) raised others split))]))))))

  (define (rejoin! h s parts)
    (let ([p (state-parent s)])
      (when (and p (memq p parts) (state-parent p) (null? (cdr (state-children p))))
        (let ([q (state-parent p)])
          (state-edits-newest-first-set! s (append (state-edits-newest-first s) (state-edits-newest-first p)))
          (state-count-set! s (fx+ (state-count s) (state-count p)))
          (state-size-set! s (fx+ (state-size s) (state-size p)))
          (state-cursors-set! s (state-cursors p))
          (state-parent-set! s q)
          (state-children-set! q (map (lambda (k) (if (eq? k p) s k)) (state-children q)))
          (when (eq? (state-left q) p) (state-left-set! q s))
          (when (eq? (history-current h) p) (history-current-set! h s))
          (when (eq? (history-stamped h) p) (history-stamped-set! h s))
          (hashtable-delete! (history-states h) (state-id p))
          (rejoin! h s parts)))))

  (define (move-target moves)
    (let ([last (car (last-pair moves))])
      (if (eq? (car last) 'undo) (state-parent (cdr last)) (cdr last))))

  ;; The whole path is played on the document first, so a step that does
  ;; not fit changes nothing. Undo's own moves are changes for the first
  ;; change rule, so undoing back to the saved text, or redoing to it,
  ;; marks the buffer unmodified again.
  (define (move! h b moves who)
    (unless (null? moves)
      (let ([target (move-target moves)] [parts '()])
        (let retry ([rest moves])
          (play (buffers:document b) (moves-steps rest) who)
          (let ([raised #f] [others '()])
            (unless (without-quits
                      (lambda ()
                        (unless (buffers:modified? b) (stamp! h b))
                        (let-values ([(whole? c edits split) (apply-moves! h b rest)])
                          (set! raised c)
                          (set! others edits)
                          (when split (set! parts (cons split parts)))
                          (queue! h (list 'at (history-current h)))
                          (mark-dirty! h)
                          whole?)))
              (cond
                [raised (raise raised)]
                [(and (pair? others) (for-all buffers:edit-silent? others) (live? h target))
                 (let ([rest (path-moves (history-current h) target)])
                   (unless (null? rest) (retry rest)))]
                [else (stale who)]))))
        (unless (null? parts)
          (without-quits
            (lambda ()
              (for-each (lambda (move) (when (live? h (cdr move)) (rejoin! h (cdr move) parts))) moves)
              (take-whole! h)))))
      (mark-if-saved! h b)))

  (define (mark-if-saved! h b)
    (when (and (eq? (history-current h) (history-stamped h)) (eqv? (history-stamp h) (buffers:save-stamp b)))
      (buffers:set-modified! b #f)))

  (define (redo-child c)
    (let ([left (state-left c)] [children (state-children c)])
      (if (and left (memq left children)) left (and (pair? children) (car children)))))

  (define (group-end s)
    (let ([e (car (state-edits-newest-first s))])
      (fx+ (edit-start e) (content-length (edit-inserted e)))))

  (define (ancestors s)
    (let loop ([s s] [acc '()])
      (if s (loop (state-parent s) (cons s acc)) acc)))

  (define (path-moves from to)
    (let loop ([up (ancestors from)] [down (ancestors to)])
      (if (and (pair? (cdr up)) (pair? (cdr down)) (eq? (cadr up) (cadr down)))
          (loop (cdr up) (cdr down))
          (append (map (lambda (s) (cons 'undo s)) (reverse (cdr up)))
                  (map (lambda (s) (cons 'redo s)) (cdr down))))))

  (define (view-of b)
    (let ([v (views:current)])
      (and v (eq? (views:buffer v) b) v)))

  (define (clamp b p)
    (fxmax 0 (fxmin p (document:length (buffers:document b)))))

  (define (restore-cursors! b points)
    (let ([v (view-of b)])
      (when (and v (pair? points))
        (let loop ([cs (views:cursors v)] [ps points])
          (cond
            [(null? ps) (for-each (lambda (c) (views:remove-cursor! v c)) cs)]
            [(null? cs) (for-each (lambda (p) (views:add-cursor! v (clamp b p))) ps)]
            [else
             (views:set-cursor! (car cs) (clamp b (car ps)) (views:cursor-mark (car cs)))
             (loop (cdr cs) (cdr ps))])))
      (void)))

  (define (place-cursors! b p)
    (let ([v (view-of b)])
      (when v
        (for-each (lambda (c) (views:set-cursor! c (clamp b p) (views:cursor-mark c))) (views:cursors v)))))

  ;; A nested body that raises takes back only the edits made since it
  ;; took its hold. The hold keeps the group's edits rather than their
  ;; count, since a silent edit can take edits of the group with it. A
  ;; condition that stops the splices is dropped, since the body's own
  ;; goes on.
  (define (cancel-group! hold b)
    (let* ([h (hold-history hold)] [o (history-open h)])
      (when (and o (installed? h) (eq? o (history-current h)))
        (let ([kept (if (eq? (hold-open hold) o) (hold-edits hold) '())])
          (define (cancelled)
            (let loop ([es (state-edits-newest-first o)])
              (if (or (null? es) (memq (car es) kept)) '() (cons (car es) (loop (cdr es))))))
          (define (end-group!)
            (cond
              [(fx> (state-count o) 0)
               (let ([written (state-written-count o)])
                 (when (and written (fx> written (state-count o)))
                   (take-whole! h)))]
              [(state-parent o)
               => (lambda (p)
                    (history-open-set! h #f)
                    (history-current-set! h p)
                    (prune! h o)
                    (queue! h (list 'at p))
                    (queue! h (list 'prune o)))]))
          (unless (null? (cancelled))
            (without-quits
              (lambda ()
                (let splice ([edits (cancelled)])
                  (let-values ([(spliced raised others) (splice-steps! h b (undo-steps edits))])
                    (drop-newest-edits! h o (or spliced (length edits)))
                    (cond
                      [(and (not raised) (pair? others) (for-all buffers:edit-silent? others)
                            (fx> (state-count o) 0))
                       (catch-up! h)
                       (when (and (live? h o) (eq? (history-current h) o))
                         (let ([edits (cancelled)])
                           (if (null? edits) (end-group!) (splice edits))))]
                      [else
                       (end-group!)
                       (when spliced (catch-up! h))])))
                (mark-dirty! h)))
            (mark-if-saved! h b))))))

  (define (end-history-batch! h)
    (when (installed? h)
      (close-group! h)
      (keep-within-limit! h)
      (when (and (installed? h) (history-open h)) (mark-dirty! h))))

  (define (end-batch!)
    (without-quits
      (lambda ()
        (release-escaped!)
        (set! command-buffer #f)
        (let ([hs dirty])
          (set! dirty '())
          (for-each (lambda (h) (history-dirty?-set! h #f) (end-history-batch! h)) hs)))))

  (define (note-command-end! command)
    (without-quits
      (lambda ()
        (set! command-buffer #f)
        (for-each close-group! dirty))))

  (define (drop! h)
    (eq-hashtable-delete! histories (history-buffer h)))

  (define (forget-history! b)
    (let ([h (eq-hashtable-ref histories b #f)])
      (when h
        (without-quits
          (lambda ()
            (history-holds-set! h '())
            (drop! h))))))

  ;; Whoever takes a history's records may rebuild its unsaved edits from
  ;; the saved text, as after a restart, so the path between the two is
  ;; kept; any other history drops its oldest groups first, as Emacs does.
  (define (kept-states h)
    (let ([kept (make-eq-hashtable)] [current (history-current h)]
          [saved (and (history-taken? h) (saved-state h))])
      (if saved
          (let ([up (ancestors current)] [down (ancestors saved)])
            (let loop ([up up] [down down])
              (if (and (pair? (cdr up)) (pair? (cdr down)) (eq? (cadr up) (cadr down)))
                  (loop (cdr up) (cdr down))
                  (for-each (lambda (s) (eq-hashtable-set! kept s #t)) (append up down)))))
          (eq-hashtable-set! kept current #t))
      kept))

  (define (holds-kept? s kept)
    (or (eq-hashtable-contains? kept s)
        (exists (lambda (k) (holds-kept? k kept)) (state-children s))))

  (define (trim! h lim)
    (let ([kept (kept-states h)])
      (let loop ()
        (when (> (history-size h) lim)
          (let* ([root (history-root h)] [children (state-children root)])
            (cond
              [(and (not (eq-hashtable-contains? kept root)) (pair? children) (null? (cdr children)))
               (re-root! h (car children))
               (queue! h (list 'root (car children)))
               (loop)]
              [(find (lambda (k) (not (holds-kept? k kept))) (reverse children))
               => (lambda (k)
                    (prune! h k)
                    (queue! h (list 'prune k))
                    (loop))]
              [else (void)]))))))

  (define (start-again! h)
    (let ([c (history-current h)])
      (warn 'undo:limit "an edit group is larger than the limit, so the buffer's history starts again"
            (list (buffers:name (history-buffer h))))
      (hashtable-clear! (history-states h))
      (hashtable-set! (history-states h) (state-id c) c)
      (state-parent-set! c #f)
      (state-edits-newest-first-set! c '())
      (state-count-set! c 0)
      (state-size-set! c 0)
      (state-children-set! c '())
      (state-left-set! c #f)
      (history-root-set! h c)
      (history-size-set! h 0)
      (forget-dead-stamp! h)
      (history-pending-set! h '())
      (take-whole! h)))

  (define (keep-within-limit! h)
    (let ([lim (limit-of (history-buffer h))])
      (cond
        [(eqv? lim 0) (drop! h)]
        [(<= (history-size h) lim) (void)]
        [(> (state-size (history-current h)) lim) (start-again! h)]
        [else (trim! h lim)])))

  (define (current-text h id doc)
    (let ([s (state-of h id)])
      (and s (fx= (state-length s) (document:length doc))
           (guard (c [(stale-condition? c) #f])
             (play doc (moves-steps (path-moves s (history-current h))) 'undo:current-document)))))

  (define (attach-buffer! b)
    (and (buffers:live? b)
         (not (eq-hashtable-ref histories b #f))
         (not (eq-hashtable-contains? attaching b))
         (begin
           (eq-hashtable-set! attaching b (box '()))
           #t)))

  (define (length-at b edits)
    (fold-left (lambda (n e)
                 (fx- n (fx- (buffers:piece-length (buffers:edit-inserted e)) (buffers:piece-length (buffers:edit-removed e)))))
               (document:length (buffers:document b)) edits))

  ;; The buffer last marked unmodified at the version holds the saved
  ;; state's text, which the history then moves on from, unless edits
  ;; since have moved it already; a buffer marked modified holds the
  ;; current state's.
  (define (install-on! b h version saved-id)
    (let ([edits (buffers:edits-since b version)])
      (if (not edits)
          (begin
            (warn 'undo "edits were made that undo could not record, so the buffer's history starts again"
                  (list (buffers:name b)))
            (mark-dirty! (begin-history! b (document:length (buffers:document b)) (buffers:version b)))
            #f)
          (let* ([h (or h (new-history 0 (length-at b edits) (now)))]
                 [saved (and saved-id (state-of h saved-id))]
                 [at-saved? (and saved (eqv? (buffers:save-stamp b) version))]
                 [target (history-current h)]
                 [at (if at-saved? saved target)])
            (and (fx= (state-length at) (length-at b edits))
                 (begin
                   (without-quits
                     (lambda ()
                       (unless (eq? at target)
                         (history-current-set! h at)
                         (queue! h (list 'at at)))
                       (when (and saved (not at-saved?) (buffers:modified? b))
                         (history-stamped-set! h saved)
                         (history-stamp-set! h (buffers:save-stamp b)))
                       (history-buffer-set! h b)
                       (history-recorded-version-set! h version)
                       (eq-hashtable-set! histories b h)
                       (mark-dirty! h)
                       (add-edits! h b edits)
                       (history-recorded-version-set! h (buffers:version b))))
                   (when (and (null? edits) (not (eq? at target)) (installed? h))
                     (move! h b (path-moves at target) 'undo:install!))
                   #t))))))

  (define (install-history! b h version saved-id)
    (let ([waiting (eq-hashtable-ref attaching b #f)])
      (eq-hashtable-delete! attaching b)
      (let ([wake (lambda () (when waiting (for-each (lambda (resume) (resume void)) (unbox waiting))))])
        (let ([installed (guard (c [#t (wake) (raise c)])
                           (and (buffers:live? b) (install-on! b h version saved-id)))])
          (wake)
          installed)))))

(import %internals)
(define (amalgamate!)
  (check-main-thread 'undo:amalgamate!)
  (let ([command (commands:this-command)] [b (buffers:current)])
    (when (and command b (eq? command (commands:last-command)))
      (let ([h (buffer-history b)])
        (when (and h (null? (history-holds h)))
          (without-quits (lambda () (amalgamate-history! h command))))))))

(define-syntax with-edit-group
  (syntax-rules ()
    [(_ buffer-expr body1 body2 ...) (call-with-edit-group buffer-expr (lambda () body1 body2 ...))]))

(define (call-with-edit-group buffer thunk)
  (check-buffer 'undo:call-with-edit-group buffer)
  (unless (procedure? thunk)
    (assertion-violation 'undo:call-with-edit-group "not a procedure" thunk))
  (let ([h (history-of 'undo:call-with-edit-group buffer)] [hold #f])
    (dynamic-wind
      (lambda ()
        (if hold
            (forget-escape! hold)
            (set! hold (take-hold! h))))
      (lambda ()
        (guard (c [(or (not (condition? c)) (serious-condition? c))
                   (cancel-group! hold buffer)
                   (release-hold! hold)
                   (raise c)])
          (call-with-values thunk
            (lambda results
              (release-hold! hold)
              (apply values results)))))
      (lambda () (leave-hold! hold)))))

;; A message during a prompt shows after its input, so in a prompt's
;; buffer, which is internal, it would only crowd what is being typed.
(define (%say! b text)
  (unless (buffers:internal-name? (buffers:name b))
    (ask:message text)))

(commands:define-command (undo [n (commands:prefix-number)])
  "Undoes the current buffer's last N edit groups and puts the view's cursors back where they were before them."
  (check-count 'undo:undo n)
  (let* ([b (current-buffer 'undo:undo)] [h (history-of 'undo:undo b)])
    (close-group! h)
    (let loop ([k n] [c (history-current h)] [moves '()])
      (if (and (fx> k 0) (state-parent c))
          (loop (fx- k 1) (state-parent c) (cons (cons 'undo c) moves))
          (begin
            (move! h b (reverse moves) 'undo:undo)
            (unless (null? moves) (restore-cursors! b (state-cursors (cdar moves))))
            (when (fx> k 0) (no-further 'undo:undo "undo"))
            (%say! b "Undo"))))))

(commands:define-command (redo [n (commands:prefix-number)])
  "Redoes N edit groups, following the branch undo last left, and puts the cursors at the end of the last one."
  (check-count 'undo:redo n)
  (let* ([b (current-buffer 'undo:redo)] [h (history-of 'undo:redo b)])
    (close-group! h)
    (let loop ([k n] [c (history-current h)] [moves '()])
      (let ([child (and (fx> k 0) (redo-child c))])
        (if child
            (loop (fx- k 1) child (cons (cons 'redo child) moves))
            (begin
              (move! h b (reverse moves) 'undo:redo)
              (unless (null? moves) (place-cursors! b (group-end (cdar moves))))
              (when (fx> k 0) (no-further 'undo:redo "redo"))
              (%say! b "Redo")))))))

(define (forget! buffer)
  (check-buffer 'undo:forget! buffer)
  (forget-history! buffer))

(define (history buffer)
  (check-buffer 'undo:history buffer)
  (let* ([h (history-of 'undo:history buffer)] [saved (saved-state h)])
    (cons* (state-id (history-current h)) (and saved (state-id saved))
           (map (lambda (s)
                  (list (state-id s) (let ([p (state-parent s)]) (and p (state-id p))) (state-time s)))
                (states-by-id h)))))

(define (go-to! buffer id)
  (check-buffer 'undo:go-to! buffer)
  (let* ([h (history-of 'undo:go-to! buffer)] [target (and (fixnum? id) (state-of h id))])
    (unless target
      (assertion-violation 'undo:go-to! "not a state of the buffer's history" id))
    (close-group! h)
    (move! h buffer (path-moves (history-current h) target) 'undo:go-to!)))

(define (take-records! buffer)
  (check-buffer 'undo:take-records! buffer)
  (take-buffer-records! buffer #f))

(define (take-all-records! buffer)
  (check-buffer 'undo:take-all-records! buffer)
  (take-buffer-records! buffer #t))

(define (records->history records)
  (unless (list? records)
    (assertion-violation 'undo:records->history "not a list" records))
  (replay records))

(define (current-document history id document)
  (unless (history? history)
    (assertion-violation 'undo:current-document "not a history" history))
  (unless (document? document)
    (assertion-violation 'undo:current-document "not a document" document))
  (and (fixnum? id) (current-text history id document)))

(define (attach! buffer)
  (check-buffer 'undo:attach! buffer)
  (attach-buffer! buffer))

(define install!
  (case-lambda
    [(buffer history version) (install! buffer history version #f)]
    [(buffer history version saved-id)
     (check-buffer 'undo:install! buffer)
     (unless (or (not history) (and (history? history) (not (history-buffer history))))
       (assertion-violation 'undo:install! "not a history on no buffer" history))
     (unless (and (fixnum? version) (fx<= 0 version (buffers:version buffer)))
       (assertion-violation 'undo:install! "not a version of the buffer" version))
     (install-history! buffer history version saved-id)]))

(add-hook! buffers:after-edit record-edit!)
(add-hook! buffers:killed forget-history!)
(add-hook! commands:before-command note-command-start!)
(add-hook! commands:after-command note-command-end!)
(advice-add! batch-ended
  (lambda (ended)
    (as-module (this-module)
      (guard (c [(not (quit-condition? c)) (report c)]) (end-batch!)))
    (ended)))
(keys:bind! keys:global "C-/" undo)
(keys:bind! keys:global "C-_" undo)
(keys:bind! keys:global "C-x u" undo)
(keys:bind! keys:global "C-?" redo)
(keys:bind! keys:global "C-M-_" redo)
