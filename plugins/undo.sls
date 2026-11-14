#!tuna
(import (buffers) (document) (views) (commands) (keys) (files) (layout) (undo log))

(define-option limit 4000000 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How large a buffer's history may grow: the characters its edits removed and inserted, plus 32 per edit. 0 keeps no history and no log.")

(define-option keep-log?
  (lambda (path)
    (not (exists (lambda (folder)
                   (let ([n (string-length folder)])
                     (and (fx>= (string-length path) n) (string=? (substring path 0 n) folder))))
                 '("/tmp/" "/dev/shm/"))))
  procedure?
  "Called with a file's path; a file buffer keeps a log only when it returns true.")

;; Saved data is kept by the plugin's source, so a fork names a folder of
;; its own and never reads the original's logs.
(define-saved %log-folder "" string?)

(module %internals
  (check-main-thread check-buffer check-count current-buffer without-quits history-of buffer-history
   state-id state-parent state-time state-cursors state-of states-by-id history-current history-saved
   history-holds close-group! take-hold! release-hold! leave-hold! forget-escape! cancel-group! move!
   redo-child group-end restore-cursors! place-cursors! path-moves no-further amalgamate-history!
   record-edit! forget-killed! note-command-start! note-command-end! attach-visited!
   attach-open-buffers note-saved! read-with-history end-batch! start-writer! stop-writer!
   ensure-log-folder!)

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
  ;; the buffer and the log's records never part company halfway.
  (define (without-quits thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  (define-record-type state
    (sealed #t)
    (fields id (mutable parent) (mutable edits-newest-first) (mutable count) (mutable time) cursors
            (mutable children) (mutable left) (mutable length) (mutable size)
            (mutable command) (mutable run) (mutable joins) (mutable written-count) (mutable queued?)))

  (define-enumeration log-rewrite (none once-edited at-batch-end) log-rewrites)

  (define-record-type history
    (sealed #t)
    (fields states (mutable buffer) (mutable root) (mutable current) (mutable saved) (mutable saves)
            (mutable next-id) (mutable size) (mutable open) (mutable holds) (mutable join)
            (mutable recorded-version) (mutable file) (mutable log) (mutable rewrite) (mutable pending)
            (mutable dirty?)))

  (define-record-type save
    (sealed #t)
    (fields state length hash))

  (define (new-history id length time)
    (let ([root (make-state id #f '() 0 time '() '() #f length 0 #f #f 0 0 #f)]
          [h (make-history (make-eqv-hashtable) #f #f #f #f '() (fx+ id 1) 0 #f '() #f 0 #f #f
                           (log-rewrite none) '() #f)])
      (hashtable-set! (history-states h) id root)
      (history-root-set! h root)
      (history-current-set! h root)
      h))

  (define (rewrite-log! h)
    (when (history-log h)
      (history-rewrite-set! h (log-rewrite at-batch-end))))

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
    (fx- (document:length (edit-inserted e)) (document:length (edit-removed e))))

  (define (edit-size e)
    (fx+ 32 (fx+ (document:length (edit-removed e)) (document:length (edit-inserted e)))))

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
            (and (fx<= (fx+ (edit-start e) (document:length (edit-removed e))) n)
                 (loop (fx+ n (edit-delta e)) (cdr es)))))))

  (define (drop-subtree! h s)
    (for-each (lambda (k) (drop-subtree! h k)) (state-children s))
    (history-size-set! h (- (history-size h) (state-size s)))
    (hashtable-delete! (history-states h) (state-id s)))

  (define (forget-dead-saves! h)
    (history-saves-set! h (filter (lambda (save) (live? h (save-state save))) (history-saves h)))
    (let ([saved (history-saved h)])
      (when (and saved (not (live? h saved)))
        (history-saved-set! h #f))))

  (define (prune! h s)
    (let ([p (state-parent s)])
      (state-children-set! p (remq s (state-children p)))
      (when (eq? (state-left p) s) (state-left-set! p #f))
      (drop-subtree! h s)
      (forget-dead-saves! h)))

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
    (forget-dead-saves! h))

  ;; Appended records cannot split a group the log holds, so the log is
  ;; written again whole.
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
      (rewrite-log! h)
      m))

  (define (descends? s ancestor)
    (let loop ([s s])
      (and s (or (eq? s ancestor) (loop (state-parent s))))))

  ;; Replaying a log stops at the first record that does not fit the
  ;; history, as at a record cut short.
  (define (apply-record! h r)
    (case (car r)
      [(group)
       (let ([id (list-ref r 1)] [p (state-of h (list-ref r 2))] [edits (list-tail r 5)])
         (and p (not (state-of h id)) (edits-fit? (state-length p) edits)
              (let ([s (add-state! h id p (list-ref r 4) (list-ref r 3))])
                (for-each (lambda (e) (push-edit! h s e)) edits)
                (state-written-count-set! s (state-count s))
                (history-current-set! h s)
                #t)))]
      [(more)
       (let ([s (state-of h (cadr r))] [edits (cddr r)])
         (and s (state-parent s) (null? (state-children s)) (edits-fit? (state-length s) edits)
              (begin
                (for-each (lambda (e) (push-edit! h s e)) edits)
                (state-written-count-set! s (state-count s))
                #t)))]
      [(at)
       (let ([s (state-of h (cadr r))])
         (and s (begin (history-current-set! h s) #t)))]
      [(saved)
       (let ([s (state-of h (cadr r))])
         (and s (begin (history-saves-set! h (cons (make-save s (caddr r) (cadddr r)) (history-saves h))) #t)))]
      [(root)
       (let ([s (state-of h (cadr r))])
         (and s (descends? (history-current h) s) (begin (re-root! h s) #t)))]
      [(prune)
       (let ([s (state-of h (cadr r))])
         (and s (state-parent s) (not (descends? (history-current h) s)) (begin (prune! h s) #t)))]
      [else #f]))

  (define (replay records)
    (if (or (null? records) (not (eq? (caar records) 'undo-history)))
        (values #f (null? records))
        (let* ([header (car records)]
               [h (new-history (list-ref header 2) (list-ref header 3) (list-ref header 4))])
          (state-written-count-set! (history-root h) 0)
          (let loop ([rs (cdr records)])
            (cond
              [(null? rs) (values h #t)]
              [(apply-record! h (car rs)) (loop (cdr rs))]
              [else (values h #f)])))))

  (define (group-record s)
    (cons* 'group (state-id s) (state-id (state-parent s)) (state-time s) (state-cursors s)
           (reverse (state-edits-newest-first s))))

  (define (saved-record save)
    (list 'saved (state-id (save-state save)) (save-length save) (save-hash save)))

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
              (map saved-record (reverse (history-saves h)))
              (list (list 'at (state-id (history-current h)))))
            (let ([s (car stack)])
              (loop (append (reverse (state-children s)) (cdr stack)) (cons (group-record s) groups)))))))

  (define (mark-written! h)
    (vector-for-each
      (lambda (s) (state-written-count-set! s (state-count s)) (state-queued?-set! s #f))
      (hashtable-values (history-states h))))

  (define (queue! h item)
    (when (history-log h)
      (history-pending-set! h (cons item (history-pending h)))))

  (define (queue-group! h s)
    (unless (state-queued? s)
      (state-queued?-set! s #t)
      (queue! h (list 'group s))))

  ;; An item naming a state whose group record never reached the log
  ;; leaves nothing, as a group undone before its batch ended.
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
                                 (reverse (list-head (state-edits-newest-first s) (fx- count written)))))]
                   [else (next #f)]))]
              [(prune) (next (and (state-written-count s) (list 'prune (state-id s))))]
              [else
               (next (and (live? h s) (state-written-count s)
                          (if (eq? kind 'saved)
                              (cons* 'saved (state-id s) (cddr item))
                              (list kind (state-id s)))))])))))

  (define (flush! h)
    (let ([log (history-log h)] [rewrite (history-rewrite h)])
      (cond
        [(not log) (history-pending-set! h '()) #f]
        [(or (eq? rewrite (log-rewrite at-batch-end))
             (and (eq? rewrite (log-rewrite once-edited)) (pair? (state-children (history-root h)))))
         (history-rewrite-set! h (log-rewrite none))
         (history-pending-set! h '())
         (mark-written! h)
         (vector 'replace log (history-records h))]
        [(eq? rewrite (log-rewrite once-edited)) (history-pending-set! h '()) #f]
        [else
         (let ([records (pending-records h)])
           (history-pending-set! h '())
           (and (pair? records) (vector 'append log records)))])))

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
    (fields history task open count))

  (define (take-hold! h)
    (without-quits
      (lambda ()
        (when (null? (history-holds h)) (close-group! h))
        (let* ([o (history-open h)] [hold (make-hold h (current-task) o (if o (state-count o) 0))])
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

  (define (keeps-log? path)
    (guard (c [(not (quit-condition? c)) (report c) #f])
      (and ((keep-log?) path) #t)))

  (define (log-file path)
    (string-append (%log-folder) (if (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\/)) "" "/")
                   path ".ss"))

  (define (log-of b path)
    (and path (fx> (limit-of b) 0) (keeps-log? path) (log-file path)))

  (define (begin-history! b length saved? version)
    (let* ([h (new-history 0 length (now))] [path (files:path b)] [log (log-of b path)])
      (history-buffer-set! h b)
      (history-recorded-version-set! h version)
      (history-file-set! h path)
      (when log
        (history-log-set! h log)
        (history-rewrite-set! h (log-rewrite once-edited)))
      (when (and path saved?)
        (let-values ([(length hash) (files:fingerprint b)])
          (let ([root (history-root h)])
            (history-saved-set! h root)
            (history-saves-set! h (list (make-save root length hash))))))
      (eq-hashtable-set! histories b h)
      h))

  (define-record-type snapshot
    (sealed #t)
    (fields path version document modified? length hash (mutable waiters)))

  (define (history-of who b)
    (or (eq-hashtable-ref histories b #f)
        (let ([snapshot (eq-hashtable-ref attaching b #f)])
          (cond
            [(not snapshot)
             (begin-history! b (document:length (buffers:document b)) (not (files:modified? b))
                             (buffers:version b))]
            [(current-task)
             (suspend
               (lambda (resume)
                 (snapshot-waiters-set! snapshot (cons resume (snapshot-waiters snapshot)))))
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
    (let* ([start (edit-start e)] [end (fx+ start (document:length (edit-inserted e)))])
      (cond
        [(fx<= p start) p]
        [(fx>= p end) (fx+ (fx- p end) (fx+ start (document:length (edit-removed e))))]
        [else start])))

  (define (cursors-before b e)
    (if (and command-buffer (eq? command-buffer b) (commands:this-command))
        command-points
        (let ([v (views:current)])
          (if (and v (eq? (views:buffer v) b))
              (map (lambda (p) (point-before p e)) (cursor-points v))
              '()))))

  (define (joins? h s command)
    (and command (state-parent s) (eq? (state-command s) command)
         (eqv? (state-run s) (fx- run 1)) (fx< (state-joins s) 20)
         (not (eq? s (history-saved h)))))

  (define (add-edit! h b e)
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
    (let-values ([(removed-spans inserted-spans) (buffers:edit-spans e)])
      (make-edit (buffers:edit-start e) (buffers:edit-removed e) (buffers:edit-inserted e)
                 removed-spans inserted-spans)))

  (define applying #f)

  (define (record-edit! b e)
    (without-quits (lambda () (note-edit! b e))))

  (define (note-edit! b e)
    (unless (eq? b applying)
      (let ([h (eq-hashtable-ref histories b #f)])
        (cond
          [(eqv? (limit) 0) (when h (forget! h #t))]
          [(eq-hashtable-contains? attaching b) (void)]
          [else
           (let ([version (buffers:edit-version e)]
                 [h (or h (begin-history! b (fx- (document:length (buffers:document b))
                                                 (fx- (document:length (buffers:edit-inserted e))
                                                      (document:length (buffers:edit-removed e))))
                                          #f (fx- (buffers:edit-version e) 1)))])
             (if (fx= version (fx+ (history-recorded-version h) 1))
                 (begin
                   (add-edit! h b (edit-of e))
                   (history-recorded-version-set! h version))
                 (catch-up! h)))]))))

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
                (for-each (lambda (e) (add-edit! h b (edit-of e))) edits)
                (history-recorded-version-set! h (buffers:version b)))
              (begin
                (warn 'undo "edits were made that undo could not record, so the buffer's history starts again"
                      (list (buffers:name b)))
                (forget! h #f)
                (mark-dirty! (begin-history! b (document:length (buffers:document b)) #f (buffers:version b)))))))))

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
    (fields start out in spans))

  (define (undo-steps s)
    (map (lambda (e) (make-step (edit-start e) (edit-inserted e) (edit-removed e) (edit-removed-spans e)))
         (state-edits-newest-first s)))

  (define (redo-steps s)
    (map (lambda (e) (make-step (edit-start e) (edit-removed e) (edit-inserted e) (edit-inserted-spans e)))
         (reverse (state-edits-newest-first s))))

  (define (move-steps move)
    (if (eq? (car move) 'undo) (undo-steps (cdr move)) (redo-steps (cdr move))))

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
        (let ([start (step-start step)] [out (step-out step)])
          (unless (holds? doc start out) (stale who))
          (guard (c [(and (assertion-violation? c) (not (quit-condition? c))) (stale who)])
            (document:replace doc start (fx+ start (document:length out)) (step-in step)))))
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
            (begin (set! applying outer) (values #f #f))
            (let* ([step (car steps)] [start (step-start step)]
                   [end (fx+ start (document:length (step-out step)))] [spans (step-spans step)]
                   [version (fx+ (buffers:version b) 1)]
                   [raised (guard (c [#t c])
                             (if spans
                                 (buffers:splice! b start end (step-in step) spans)
                                 (buffers:splice! b start end (step-in step)))
                             #f)]
                   [made? (fx>= (buffers:version b) version)]
                   [n (if made? (fx+ n 1) n)])
              (when made? (history-recorded-version-set! h version))
              (if (and (not raised) (fx= (buffers:version b) version))
                  (loop (cdr steps) n)
                  (begin (set! applying outer) (values n raised))))))))

  ;; A move cut short stops where it is: the steps spliced become a state
  ;; of their own and edits made meanwhile a group after it, so the
  ;; history still matches the buffer.
  (define (apply-moves! h b moves)
    (let loop ([moves moves])
      (if (null? moves)
          (values #t #f)
          (let* ([move (car moves)] [s (cdr move)] [undo? (eq? (car move) 'undo)] [n (state-count s)])
            (let-values ([(spliced raised) (splice-steps! h b (move-steps move))])
              (define (reach! child)
                (state-left-set! (state-parent child) child)
                (history-current-set! h (if (and undo? (eq? child s)) (state-parent s) child)))
              (cond
                [(not spliced) (reach! s) (loop (cdr moves))]
                [else
                 (cond
                   [(fx= spliced n) (reach! s)]
                   [(fx> spliced 0) (reach! (split-state! h s (if undo? spliced (fx- n spliced))))])
                 (close-group! h)
                 (values (and (not raised) (fx= spliced n) (null? (cdr moves))) raised)]))))))

  ;; The whole path is played on the document first, so a step that does
  ;; not fit changes nothing.
  (define (move! h b moves who)
    (unless (null? moves)
      (play (buffers:document b) (moves-steps moves) who)
      (let ([raised #f])
        (unless (without-quits
                  (lambda ()
                    (let-values ([(whole? c) (apply-moves! h b moves)])
                      (set! raised c)
                      (queue! h (list 'at (history-current h)))
                      (mark-dirty! h)
                      whole?)))
          (if raised (raise raised) (stale who))))
      (when (eq? (history-current h) (history-saved h))
        (files:not-modified b))))

  (define (redo-child c)
    (let ([left (state-left c)] [children (state-children c)])
      (if (and left (memq left children)) left (and (pair? children) (car children)))))

  (define (group-end s)
    (let ([e (car (state-edits-newest-first s))])
      (fx+ (edit-start e) (document:length (edit-inserted e)))))

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
  ;; took its hold. A condition that stops the splices is dropped, since
  ;; the body's own goes on.
  (define (cancel-group! hold b)
    (let* ([h (hold-history hold)] [o (history-open h)])
      (when (and o (installed? h) (eq? o (history-current h)))
        (let ([since (if (eq? (hold-open hold) o) (hold-count hold) 0)])
          (when (fx> (state-count o) since)
            (without-quits
              (lambda ()
                (let*-values ([(steps) (list-head (undo-steps o) (fx- (state-count o) since))]
                              [(spliced raised) (splice-steps! h b steps)])
                  (drop-newest-edits! h o (or spliced (length steps)))
                  (if (fx> (state-count o) 0)
                      (let ([written (state-written-count o)])
                        (when (and written (fx> written (state-count o)))
                          (rewrite-log! h)))
                      (let ([p (state-parent o)])
                        (history-open-set! h #f)
                        (history-current-set! h p)
                        (prune! h o)
                        (queue! h (list 'at p))
                        (queue! h (list 'prune o))))
                  (when spliced (catch-up! h))
                  (mark-dirty! h)))))))))

  (define writer-items '())

  (define (end-history-batch! h)
    (when (installed? h)
      (close-group! h)
      (let ([item (flush! h)])
        (when item (set! writer-items (cons item writer-items))))
      (keep-within-limit! h)
      (when (installed? h)
        (let ([item (flush! h)])
          (when item (set! writer-items (cons item writer-items))))
        (when (history-open h) (mark-dirty! h)))))

  (define (end-batch!)
    (without-quits
      (lambda ()
        (release-escaped!)
        (set! command-buffer #f)
        (let ([hs dirty])
          (set! dirty '())
          (for-each (lambda (h) (history-dirty?-set! h #f) (end-history-batch! h)) hs)
          (send-items!)))))

  (define (send-items!)
    (let ([items (reverse writer-items)])
      (set! writer-items '())
      (unless (null? items) (send! items))))

  (define (note-command-end! command)
    (without-quits
      (lambda ()
        (set! command-buffer #f)
        (for-each close-group! dirty))))

  ;; The item follows those a batch's end has queued, so a deleted log is
  ;; not written again by an append queued before it.
  (define (forget! h delete?)
    (eq-hashtable-delete! histories (history-buffer h))
    (let ([item (if delete?
                    (let ([log (history-log h)]) (and log (vector 'delete log)))
                    (flush! h))])
      (when item
        (set! writer-items (cons item writer-items))
        (send-items!))))

  ;; The discarded edits stay a redo away and do not come back at the
  ;; next visit.
  (define (forget-killed! b)
    (let ([h (eq-hashtable-ref histories b #f)])
      (when h
        (without-quits
          (lambda ()
            (history-holds-set! h '())
            (close-group! h)
            (let ([saved (history-saved h)])
              (when (and saved (not (eq? saved (history-current h))))
                (history-current-set! h saved)
                (queue! h (list 'at saved))))
            (forget! h #f))))))

  ;; The path from the saved state to the current one is kept, since a
  ;; restart needs it.
  (define (kept-states h)
    (let ([kept (make-eq-hashtable)] [current (history-current h)] [saved (history-saved h)])
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
      (forget-dead-saves! h)
      (history-pending-set! h '())
      (rewrite-log! h)))

  (define (keep-within-limit! h)
    (let ([lim (limit-of (history-buffer h))])
      (cond
        [(eqv? lim 0) (forget! h #t)]
        [(<= (history-size h) lim) (void)]
        [(> (state-size (history-current h)) lim) (start-again! h)]
        [else (trim! h lim)])))

  (define (note-saved! b)
    (without-quits (lambda () (mark-saved! b))))

  ;; A buffer written to another file keeps its history, which the new
  ;; file's log holds whole; the old log gets the records made before.
  (define (mark-saved! b)
    (let ([h (eq-hashtable-ref histories b #f)])
      (if (not h)
          (unless (eq-hashtable-contains? attaching b)
            (mark-dirty! (begin-history! b (document:length (buffers:document b)) (not (files:modified? b))
                                         (buffers:version b))))
          (let ([path (files:path b)])
            (close-group! h)
            (unless (equal? path (history-file h))
              (let ([item (flush! h)] [log (log-of b path)])
                (when item (send! (list item)))
                (history-file-set! h path)
                (history-log-set! h log)
                (rewrite-log! h)))
            (if (or (history-open h) (files:modified? b))
                (history-saved-set! h #f)
                (let-values ([(length hash) (files:fingerprint b)])
                  (let ([c (history-current h)])
                    (history-saved-set! h c)
                    (history-saves-set! h (cons (make-save c length hash)
                                                (remp (lambda (save) (eq? (save-state save) c))
                                                      (history-saves h))))
                    (queue! h (list 'saved c length hash)))))
            (mark-dirty! h)))))

  (define (saved-match h length hash text-length)
    (let ([save (find (lambda (save)
                        (and (= (save-length save) length) (= (save-hash save) hash)
                             (or (not text-length) (fx= (state-length (save-state save)) text-length))))
                      (history-saves h))])
      (and save (save-state save))))

  (define (unsaved-edits? h)
    (and (pair? (state-children (history-root h)))
         (let ([saves (history-saves h)])
           (or (null? saves) (not (eq? (save-state (car saves)) (history-current h)))))))

  (define (start-over old text-length length hash path log saved?)
    (when (and old (unsaved-edits? old))
      (send! (list (vector 'aside log)))
      (warn 'undo "the file changed outside Tuna, so the log of its unsaved edits is set aside as"
            (list (string-append log ".stale"))))
    (let ([h (new-history 0 text-length (now))])
      (history-file-set! h path)
      (history-log-set! h log)
      (when log (history-rewrite-set! h (log-rewrite once-edited)))
      (when saved?
        (let ([root (history-root h)])
          (history-saved-set! h root)
          (history-saves-set! h (list (make-save root length hash)))))
      h))

  ;; A log that cannot be read is left alone, and its buffer keeps no log
  ;; this session: writing a new one would replace the unsaved edits it
  ;; may hold.
  (define (read-history log)
    (let-values ([(records torn?) (suspend (lambda (resume) (send! (list (vector 'read log resume)))))])
      (if records
          (let-values ([(h fits?) (replay records)])
            (when h
              (history-file-set! h #f)
              (history-log-set! h log)
              (when (or torn? (not fits?))
                (rewrite-log! h)))
            (values h log))
          (values #f #f))))

  (define (adopt! h path log)
    (history-file-set! h path)
    (history-log-set! h log)
    h)

  (define (choose-history old doc modified? length hash path log)
    (let ([text-length (document:length doc)])
      (define (over) (values (start-over old text-length length hash path log (not modified?)) '() doc))
      (cond
        [(not old) (over)]
        [modified?
         (if (fx= (state-length (history-current old)) text-length)
             (begin
               (history-saved-set! old (saved-match old length hash #f))
               (values (adopt! old path log) '() doc))
             (over))]
        [(saved-match old length hash text-length)
         => (lambda (s)
              (let* ([moves (path-moves s (history-current old))]
                     [shown (guard (c [(stale-condition? c) #f]) (play doc (moves-steps moves) 'undo))])
                (if shown
                    (begin
                      (history-saved-set! old s)
                      (values (adopt! old path log) moves shown))
                    (over))))]
        [else (over)])))

  (define prepared (make-weak-eq-hashtable))

  ;; files:read-document's advice: the visit makes its buffer with the
  ;; unsaved edits already in, so views restore their cursors on the text
  ;; they were on.
  (define (read-with-history read path)
    (let-values ([(doc length hash) (read path)])
      (let ([log (and (string? path) (current-task) (fx> (limit) 0) (keeps-log? path) (log-file path))])
        (if (not log)
            (values doc length hash)
            (let-values ([(old log) (read-history log)])
              (let-values ([(h moves shown) (choose-history old doc #f length hash path log)])
                (eq-hashtable-set! prepared (current-task) h)
                (values shown length hash)))))))

  (define (install! b h v0)
    (without-quits
      (lambda ()
        (history-buffer-set! h b)
        (eq-hashtable-set! histories b h)
        (mark-dirty! h)
        (unless (= (buffers:version b) v0)
          (let ([edits (buffers:edits-since b v0)])
            (if edits
                (for-each (lambda (e) (add-edit! h b (edit-of e))) edits)
                (begin
                  (eq-hashtable-delete! histories b)
                  (mark-dirty! (begin-history! b (document:length (buffers:document b)) #f (buffers:version b)))))))
        (history-recorded-version-set! h (buffers:version b)))))

  ;; Edits made while the log was read apply to the saved text, so the
  ;; log's unsaved edits stay a redo away rather than being replayed.
  (define (attach-live! b old doc0 v0 modified? length hash path log)
    (let-values ([(h moves shown) (choose-history old doc0 modified? length hash path log)])
      (if (null? moves)
          (install! b h v0)
          (let ([saved (history-saved h)])
            (history-current-set! h saved)
            (queue! h (list 'at saved))
            (install! b h v0)
            (when (and (installed? h) (eq? (history-current h) saved))
              (move! h b moves 'undo))))))

  ;; Attaching a live buffer begins at once, so an edit made, or a history
  ;; asked for, before its log arrives neither goes unrecorded nor starts
  ;; a history of its own.
  (define (begin-attach! b)
    (and (not (eq-hashtable-ref histories b #f))
         (not (eq-hashtable-contains? attaching b))
         (files:path b)
         (let-values ([(length hash) (files:fingerprint b)])
           (let ([snapshot (make-snapshot (files:path b) (buffers:version b) (buffers:document b)
                                          (files:modified? b) length hash '())])
             (eq-hashtable-set! attaching b snapshot)
             snapshot))))

  (define (end-attach! b snapshot)
    (eq-hashtable-delete! attaching b)
    (for-each (lambda (resume) (resume void)) (snapshot-waiters snapshot)))

  (define (finish-attach! b snapshot)
    (let ([path (snapshot-path snapshot)])
      (let-values ([(old log) (let ([log (log-of b path)])
                                (if log
                                    (guard (c [#t (end-attach! b snapshot) (raise c)])
                                      (read-history log))
                                    (values #f #f)))])
        (end-attach! b snapshot)
        (when (and (buffers:live? b) (not (eq-hashtable-ref histories b #f)) (equal? (files:path b) path))
          (attach-live! b old (snapshot-document snapshot) (snapshot-version snapshot)
                        (snapshot-modified? snapshot) (snapshot-length snapshot) (snapshot-hash snapshot)
                        path log)))))

  (define (attach-visited! b)
    (let ([h (eq-hashtable-ref prepared (current-task) #f)])
      (when h (eq-hashtable-delete! prepared (current-task)))
      (if (and h (equal? (history-file h) (files:path b)) (not (eq-hashtable-ref histories b #f)))
          (install! b h 0)
          (let ([snapshot (begin-attach! b)])
            (when snapshot (finish-attach! b snapshot))))))

  ;; Attaching begins in the module's body, before any edit can come, and
  ;; finishes in a task, which may pause for the logs.
  (define (attach-open-buffers)
    (let ([started (filter cdr (map (lambda (b) (cons b (begin-attach! b))) (files:buffers)))])
      (lambda ()
        (for-each
          (lambda (entry)
            (guard (c [(not (quit-condition? c)) (report c)])
              (finish-attach! (car entry) (cdr entry))))
          started))))

  (define (compact! log)
    (let ([h (find (lambda (h) (equal? (history-log h) log)) (vector->list (hashtable-values histories)))])
      (when (and h (eq? (history-rewrite h) (log-rewrite none)))
        (rewrite-log! h)
        (mark-dirty! h))))

  (define (ensure-log-folder!)
    (when (string=? (%log-folder) "")
      (let ([t (current-time 'time-utc)])
        (set-saved! %log-folder
          (format "~a/.local/share/tuna/undo/~a" (getenv "HOME")
                  (+ (* (time-second t) 1000000000) (time-nanosecond t)))))))

  ;; The logs have a thread of their own, not jobs: a file's reads and
  ;; appends must keep their order, and a job stops when its module
  ;; unloads, before an unload action could wait for its last write.
  (define writer-mutex (make-mutex))
  (define writer-work (make-condition))
  (define writer-idle (make-condition))
  (define writer-queue '())
  (define writer-busy? #f)
  (define writer-stopping? #f)

  (define (answer-reads! items)
    (for-each
      (lambda (item)
        (when (eq? (vector-ref item 0) 'read)
          ((vector-ref item 2) (lambda () (values #f #f)))))
      items))

  (define (send! items)
    (unless (without-quits
              (lambda ()
                (with-mutex writer-mutex
                  (and (not writer-stopping?)
                       (begin
                         (set! writer-queue (append (reverse items) writer-queue))
                         (condition-signal writer-work)
                         #t)))))
      (answer-reads! items)))

  (define (take-work!)
    (with-mutex writer-mutex
      (let loop ()
        (cond
          [(pair? writer-queue)
           (let ([items (reverse writer-queue)])
             (set! writer-queue '())
             (set! writer-busy? #t)
             items)]
          [else
           (set! writer-busy? #f)
           (condition-broadcast writer-idle)
           (and (not writer-stopping?)
                (begin (condition-wait writer-work writer-mutex) (loop)))]))))

  ;; A log is written again from its history, which drops the records that
  ;; no longer count, once it has grown past twice its size when last
  ;; read or written whole: each byte is then written about twice at most.
  ;; The 64 KB more spares small logs the fixed cost of three flushes.
  (define sizes (make-hashtable string-hash string=?))

  (define (report-later c) (post! (lambda () (report c))))

  (define (attempt thunk)
    (guard (c [#t (report-later c)]) (thunk)))

  (define (note-size! file n)
    (hashtable-set! sizes file (cons n n)))

  (define (append-records! file records)
    (let ([bytes (records->bytes records)])
      (unless (hashtable-contains? sizes file)
        (note-size! file (log-size file)))
      (append-log! file bytes)
      (let* ([entry (hashtable-ref sizes file #f)] [size (+ (cdr entry) (bytevector-length bytes))])
        (if (> size (+ (* 2 (car entry)) 65536))
            (begin
              (note-size! file size)
              (post! (lambda () (compact! file))))
            (set-cdr! entry size)))))

  (define (replace-records! file records)
    (let ([bytes (records->bytes records)])
      (replace-log! file bytes)
      (note-size! file (bytevector-length bytes))))

  (define (answer-read! file resume)
    (let-values ([(records torn?)
                  (guard (c [#t (report-later c) (values #f #f)])
                    (let-values ([(records torn?) (read-log file)])
                      (note-size! file (log-size file))
                      (values records torn?)))])
      (attempt (lambda () (resume (lambda () (values records torn?)))))))

  ;; Appends to one log are written together, with one flush to disk, but
  ;; never past another item for the same log.
  (define (write-round! items)
    (let ([appends '()])
      (define (flush-appends! file)
        (let ([entry (assoc file appends)])
          (when entry
            (set! appends (remq entry appends))
            (attempt (lambda () (append-records! file (reverse (cdr entry))))))))
      (for-each
        (lambda (item)
          (let ([kind (vector-ref item 0)] [file (vector-ref item 1)])
            (if (eq? kind 'append)
                (let ([entry (assoc file appends)])
                  (if entry
                      (set-cdr! entry (append (reverse (vector-ref item 2)) (cdr entry)))
                      (set! appends (cons (cons file (reverse (vector-ref item 2))) appends))))
                (begin
                  (flush-appends! file)
                  (case kind
                    [(replace) (attempt (lambda () (replace-records! file (vector-ref item 2))))]
                    [(read) (answer-read! file (vector-ref item 2))]
                    [(aside) (attempt (lambda () (set-log-aside! file) (hashtable-delete! sizes file)))]
                    [(delete) (attempt (lambda () (delete-log! file) (hashtable-delete! sizes file)))])))))
        items)
      (for-each (lambda (entry) (flush-appends! (car entry))) (reverse appends))))

  (define (run-writer)
    (let loop ()
      (let ([items (take-work!)])
        (when items
          (write-round! items)
          (loop)))))

  (define (start-writer!) (fork-thread run-writer))

  ;; Exit unloads this module too, so the wait is bounded: a round that
  ;; prints a huge edit could otherwise hold exit for seconds. A round
  ;; still running when the wait ends goes on, and can append to a log as
  ;; a reloaded instance's writer does.
  (define writer-wait 2)

  (define (stop-writer!)
    (for-each (lambda (h) (history-dirty?-set! h #f) (end-history-batch! h)) dirty)
    (set! dirty '())
    (send-items!)
    (with-mutex writer-mutex
      (set! writer-stopping? #t)
      (condition-signal writer-work))
    (let ([deadline (add-duration (current-time 'time-utc) (make-time 'time-duration 0 writer-wait))])
      (unless (with-mutex writer-mutex
                (let loop ()
                  (cond
                    [(not (or writer-busy? (pair? writer-queue))) #t]
                    [(or (condition-wait writer-idle writer-mutex deadline)
                         (time<? (current-time 'time-utc) deadline))
                     (loop)]
                    [else
                     (let ([dropped writer-queue])
                       (set! writer-queue '())
                       (answer-reads! dropped)
                       #f)])))
        (warn 'undo (format "the log writer did not finish within ~a seconds; the edits it had not written are not in the logs"
                            writer-wait)
              '())))))

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
            (when (fx> k 0) (no-further 'undo:undo "undo")))))))

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
              (when (fx> k 0) (no-further 'undo:redo "redo"))))))))

(define (history buffer)
  (check-buffer 'undo:history buffer)
  (let* ([h (history-of 'undo:history buffer)] [saved (history-saved h)])
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

(ensure-log-folder!)
(start-writer!)
(add-hook! buffers:after-edit record-edit!)
(add-hook! buffers:killed forget-killed!)
(add-hook! commands:before-command note-command-start!)
(add-hook! commands:after-command note-command-end!)
;; Ahead of other entries, whose edits would otherwise start a history of
;; their own in place of the log's.
(add-hook! files:after-visit attach-visited! -100)
(add-hook! files:after-save note-saved!)
(add-hook! files:after-revert note-saved!)
(advice-add! files:read-document read-with-history)
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
;; Window changes are not text, as Emacs keeps them out of buffer undo:
;; an undo must never take back a part a plugin placed or removed.
(buffers:with-buffer layout:buffer (set-option-local! limit 0))
(on-unload stop-writer!)
(spawn-task (attach-open-buffers))
