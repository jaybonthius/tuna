#!tuna
(import (buffers) (files) (undo) (undo-log disk) (ask) (hooks) (options) (scopes) (saved))

(define %self (current-owner))

(options:define-option keep-log?
  (lambda (path)
    (not (exists (lambda (folder)
                   (let ([n (string-length folder)])
                     (and (fx>= (string-length path) n) (string=? (substring path 0 n) folder))))
                 '("/tmp/" "/dev/shm/"))))
  procedure?
  "Called with a file's path; a file buffer keeps a log only when it returns true.")

;; Saved data is kept by the plugin's source, so a fork names a folder of
;; its own and never reads the original's logs.
(saved:define-saved %log-folder "" string?)

(module %internals
  (read-with-log note-visit! note-saved! note-killed! note-silent-edit! note-rename! flush-logs! logged?
   attach-open-buffers start-writer! stop! ensure-log-folder!)

  (define (warn who message . irritants)
    (report (condition (make-warning) (make-who-condition who) (make-format-condition)
                       (make-message-condition message) (make-irritants-condition irritants))))

  (define (without-cancels thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  ;; A save waits for the batch's end before it names a state, since the
  ;; state saved is undo's to tell once the batch's edits are in.
  (define-record-type entry
    (sealed #t)
    (fields buffer (mutable path) (mutable file) (mutable saves) (mutable written?) (mutable whole?)
            (mutable ready?) (mutable save) (mutable queued)))

  (define logs (make-weak-eq-hashtable))

  ;; A buffer whose log could not be read keeps none for the session, so
  ;; the edits that log may hold are never written over.
  (define unreadable-logs (make-weak-eq-hashtable))

  (define (unreadable-log! b path)
    (eq-hashtable-delete! logs b)
    (eq-hashtable-set! unreadable-logs b path))

  (define (entry-of b)
    (let ([entry (eq-hashtable-ref logs b #f)])
      (and entry (entry-ready? entry) entry)))

  ;; A silent edit that changes tokens is in no record, and undo moves
  ;; the saved state past it, so the saved file no longer fits the log and
  ;; its unsaved edits cannot be rebuilt. One that changes none leaves
  ;; undo's history, and the log still rebuilds the tokens.
  (define silenced (make-weak-eq-hashtable))

  (define (note-silent-edit! b e)
    (when (and (buffers:edit-silent? e) (buffers:edit-moves? e) (eq-hashtable-contains? logs b))
      (eq-hashtable-set! silenced b #t)))

  ;; A log rebuilds unsaved edits from a saved state, so a history with
  ;; none, as after undo:forget! or a group larger than the limit, or
  ;; whose saved state the log has no record of, as for edits made while
  ;; the buffer kept no log, has edits no log can bring back.
  (define (logged? b)
    (let ([entry (entry-of b)])
      (and entry (equal? (logged-path b) (entry-path entry))
           (not (eq-hashtable-contains? silenced b))
           (let ([saved (cadr (undo:history b))])
             (and saved (or (assv saved (entry-saves entry)) (entry-save entry)) #t)))))

  (define (keeps-log? path)
    (guard (c [(not (cancelled? c)) (report c) #f])
      (and ((keep-log?) path) #t)))

  (define (log-name path)
    (string-append (%log-folder) (if (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\/)) "" "/")
                   path))

  (define (log-file path) (string-append (log-name path) ".ss"))

  (define (limit-of b) (buffers:with-buffer b (undo:limit)))

  (define (logged-path b)
    (let ([path (files:path b)])
      (and path (fx> (limit-of b) 0) (keeps-log? path) path)))

  (define (add-entry! b path saves written? whole?)
    (let ([entry (make-entry b path (log-file path) saves written? whole? #t #f '())])
      (eq-hashtable-set! logs b entry)
      entry))

  (define (whole-records? records)
    (and (pair? records) (eq? (caar records) 'undo-history)))

  (define (group? r) (eq? (car r) 'group))

  (define (record-ids records)
    (let ([ids (make-eqv-hashtable)])
      (hashtable-set! ids (caddr (car records)) #t)
      (for-each (lambda (r) (when (group? r) (hashtable-set! ids (cadr r) #t))) records)
      ids))

  (define (saved-record save) (cons 'saved save))

  ;; A whole history ends with its current state; the saves go before it.
  (define (with-saves! entry records)
    (let* ([ids (record-ids records)]
           [saves (filter (lambda (save) (hashtable-ref ids (car save) #f)) (entry-saves entry))]
           [n (length records)])
      (entry-saves-set! entry saves)
      (append (list-head records (fx- n 1)) (map saved-record (reverse saves)) (list-tail records (fx- n 1)))))

  (define (note-save! entry id fingerprint)
    (let ([save (cons id fingerprint)])
      (entry-saves-set! entry (cons save (remp (lambda (s) (eqv? (car s) id)) (entry-saves entry))))
      (entry-queued-set! entry (cons (saved-record save) (entry-queued entry)))))

  (define (place-save! entry)
    (let ([fingerprint (entry-save entry)])
      (when fingerprint
        (entry-save-set! entry #f)
        (let ([saved (cadr (undo:history (entry-buffer entry)))])
          (when saved (note-save! entry saved fingerprint))))))

  ;; A log is first written once its history holds an edit group, so a
  ;; file visited and left alone gets none.
  (define (flush-log! entry)
    (let* ([b (entry-buffer entry)] [forced? (entry-whole? entry)]
           [records (if forced? (undo:take-all-records! b) (undo:take-records! b))])
      (entry-whole?-set! entry #f)
      (cond
        [(not records)
         (when (entry-written? entry)
           (send! (list (vector 'delete (entry-file entry)))))
         (entry-written?-set! entry #f)
         (entry-saves-set! entry '())
         (entry-save-set! entry #f)
         (entry-queued-set! entry '())]
        [else
         (place-save! entry)
         (let ([queued (reverse (entry-queued entry))])
           (entry-queued-set! entry '())
           (cond
             [(whole-records? records)
              (when (or forced? (entry-written? entry) (exists group? records))
                (send! (list (vector 'replace (entry-file entry) (with-saves! entry records))))
                (entry-written?-set! entry #t))]
             [(entry-written? entry)
              (let ([all (append records queued)])
                (unless (null? all)
                  (send! (list (vector 'append (entry-file entry) all)))))]
             [(exists group? records)
              (entry-whole?-set! entry #t)
              (flush-log! entry)]))])))

  ;; A buffer that went without the killed hook, as when buffers reloads,
  ;; has no history left to take, which must not delete its log.
  (define (flush-logs!)
    (without-cancels
      (lambda ()
        (vector-for-each
          (lambda (entry)
            (let ([b (entry-buffer entry)])
              (cond
                [(not (buffers:live? b)) (eq-hashtable-delete! logs b)]
                [(entry-ready? entry) (flush-log! entry)])))
          (hashtable-values logs)))))

  (define (read-records file)
    (suspend (lambda (resume) (send! (list (vector 'read file resume))))))

  (define (split-records records)
    (let loop ([rs records] [kept '()] [saves '()])
      (cond
        [(null? rs) (values (reverse kept) saves)]
        [(eq? (caar rs) 'saved) (loop (cdr rs) kept (cons (cdar rs) saves))]
        [else (loop (cdr rs) (cons (car rs) kept) saves)])))

  (define (matching saves length hash)
    (map car (filter (lambda (save) (and (= (cadr save) length) (= (caddr save) hash))) saves)))

  (define (unsaved-edits? records saves)
    (let loop ([rs records] [current #f])
      (if (null? rs)
          (and current (or (null? saves) (not (eqv? (caar saves) current))))
          (loop (cdr rs) (if (memq (caar rs) '(group at)) (cadar rs) current)))))

  (define (other-version? records)
    (and (pair? records) (eq? (caar records) 'undo-history) (not (eqv? (cadar records) undo:records-version))))

  ;; The writer names the log set aside once it is renamed, since it is
  ;; never renamed over an earlier one. A log of another version is kept
  ;; whatever it holds: this version cannot read its unsaved edits.
  (define (set-aside! path file records saves)
    (define (aside! message) (send! (list (vector 'aside file message path))))
    (cond
      [(other-version? records)
       (aside! "the log of edits to ~a is from another version of Tuna, so it is set aside as ~a")]
      [(unsaved-edits? records saves)
       (aside! "~a changed outside Tuna, so the log of its unsaved edits is set aside as ~a")]))

  (define (say-restored! b)
    (ask:message (format "restored unsaved edits to ~a" (buffers:name b))))

  (define-record-type prepared
    (sealed #t)
    (fields path unreadable? history saved saves rewrite?))

  (define prepared-visits (make-weak-eq-hashtable))

  ;; The visit makes its buffer with the unsaved edits already in, so
  ;; views restore their cursors on the text they were on.
  (define (read-with-log read path)
    (let-values ([(doc length hash) (read path)])
      (let ([file (and (string? path) (current-task) (fx> (parameterize ([scopes:current #f]) (undo:limit)) 0)
                       (keeps-log? path) (log-file path))])
        (if (not file)
            (values doc length hash)
            (let-values ([(records torn?) (read-records file)])
              (if (not records)
                  (begin
                    (eq-hashtable-set! prepared-visits (current-task) (make-prepared path #t #f #f '() #f))
                    (values doc length hash))
                  (let*-values ([(kept saves) (split-records records)]
                                [(h fits?) (undo:records->history kept)])
                    (let loop ([ids (if h (matching saves length hash) '())])
                      (cond
                        [(null? ids)
                         (set-aside! path file kept saves)
                         (eq-hashtable-set! prepared-visits (current-task) (make-prepared path #f #f #f '() #f))
                         (values doc length hash)]
                        [(undo:current-document h (car ids) doc)
                         => (lambda (shown)
                              (eq-hashtable-set! prepared-visits (current-task)
                                (make-prepared path #f h (car ids) saves (or torn? (not fits?))))
                              (values shown length hash))]
                        [else (loop (cdr ids))])))))))))

  (define (note-pending-save! entry b)
    (unless (buffers:modified? b)
      (let-values ([(length hash) (files:fingerprint b)])
        (entry-save-set! entry (list length hash)))))

  ;; An install that finds the buffer's edits since the version gone has
  ;; started a new history already, which undo:attach! then refuses.
  (define (start! b path version prepared)
    (let ([h (prepared-history prepared)])
      (if (and h (undo:install! b h version (prepared-saved prepared)))
          (begin
            (add-entry! b path (prepared-saves prepared) #t (prepared-rewrite? prepared))
            #t)
          (begin
            (when (or (not h) (undo:attach! b))
              (undo:install! b #f version))
            (note-pending-save! (add-entry! b path '() #f #f) b)
            #f))))

  (define-record-type snapshot
    (sealed #t)
    (fields path version document modified? length hash))

  (define attaching '())

  ;; Attaching begins at once, so no edit made before the log arrives goes
  ;; unrecorded or starts a history of its own; whether the file keeps a
  ;; log is asked when it finishes, after the configuration's settings. A
  ;; buffer undo already keeps a history for, as when this plugin alone
  ;; reloads, keeps it, and its log is written again whole once its saves
  ;; are read.
  (define (begin-attach! b)
    (let ([path (files:path b)])
      (cond
        [(not path) #f]
        [(undo:attach! b)
         (let-values ([(length hash) (files:fingerprint b)])
           (let ([snapshot (make-snapshot path (buffers:version b) (buffers:document b) (buffers:modified? b)
                                          length hash)])
             (set! attaching (cons (cons b snapshot) attaching))
             (lambda () (finish-attach! b snapshot))))]
        [else
         (let ([begun (and (not (buffers:modified? b))
                           (let-values ([(length hash) (files:fingerprint b)])
                             (list (cadr (undo:history b)) length hash)))])
           (lambda ()
             (when (and (buffers:live? b) (equal? (logged-path b) path))
               (let ([entry (make-entry b path (log-file path) '() #t #t #f #f '())])
                 (eq-hashtable-set! logs b entry)
                 (read-saves! entry begun)))))])))

  ;; A buffer with no log yet gets one as a visit does: once its history
  ;; holds a group, and with the saved text's fingerprint, without which
  ;; the next visit could not rebuild its edits. An edit made while the
  ;; log is read leaves no unmodified moment to take the fingerprint in,
  ;; so the one taken as the attach began serves while the saved state is
  ;; still the one it was taken for.
  (define (read-saves! entry begun)
    (let ([b (entry-buffer entry)])
      (let-values ([(records torn?) (read-records (entry-file entry))])
        (cond
          [(not records) (unreadable-log! b (entry-path entry))]
          [else
           (if (other-version? records)
               (set-aside! (entry-path entry) (entry-file entry) records '())
               (let-values ([(kept saves) (split-records records)])
                 (entry-saves-set! entry saves)))
           (when (and (or (null? records) (other-version? records)) (equal? (files:path b) (entry-path entry)))
             (entry-written?-set! entry #f)
             (entry-whole?-set! entry #f)
             (if (and begun (eqv? (car begun) (cadr (undo:history b))))
                 (entry-save-set! entry (cdr begun))
                 (note-pending-save! entry b)))
           (entry-ready?-set! entry #t)]))))

  (define (end-attach! b)
    (and (assq b attaching)
         (begin
           (set! attaching (remp (lambda (a) (eq? (car a) b)) attaching))
           #t)))

  ;; A cancel ends the task quietly: the stop an unload sends comes
  ;; after the unload actions have ended its attach.
  (define (finish-attach! b snapshot)
    (let* ([version (snapshot-version snapshot)] [path (snapshot-path snapshot)]
           [file (and (buffers:live? b) (equal? (logged-path b) path) (log-file path))])
      (let-values ([(records torn?)
                    (guard (c [#t (when (end-attach! b) (undo:install! b #f version))
                                  (if (cancelled? c) (values 'stopped #f) (raise c))])
                      (if file (read-records file) (values #f #f)))])
        (end-attach! b)
        (cond
          [(eq? records 'stopped) (void)]
          [(not (and records (buffers:live? b) (equal? (files:path b) path)))
           (undo:install! b #f version)
           (when (and file (not records)) (unreadable-log! b path))]
          [else
           (let*-values ([(kept saves) (split-records records)]
                         [(h fits?) (undo:records->history kept)]
                         [(ids) (if h (matching saves (snapshot-length snapshot) (snapshot-hash snapshot)) '())]
                         [(saved) (if (snapshot-modified? snapshot)
                                      (and (pair? ids) (car ids))
                                      (find (lambda (id) (undo:current-document h id (snapshot-document snapshot))) ids))]
                         [(unedited?) (fx= (buffers:version b) version)])
             (cond
               [(not (start! b path version
                       (if (and h (or saved (snapshot-modified? snapshot)))
                           (make-prepared path #f h saved saves (or torn? (not fits?)))
                           (make-prepared path #f #f #f '() #f))))
                (set-aside! path file kept saves)]
               [(and unedited? (not (snapshot-modified? snapshot)) (buffers:modified? b)) (say-restored! b)]))]))))

  (define (note-visit! b)
    (let ([p (eq-hashtable-ref prepared-visits (current-task) #f)])
      (when p (eq-hashtable-delete! prepared-visits (current-task)))
      (let ([path (logged-path b)])
        (cond
          [(not path) (void)]
          [(and p (prepared-unreadable? p)) (unreadable-log! b path)]
          [(and p (equal? (prepared-path p) path))
           (start! b path 0 p)
           (when (buffers:modified? b) (say-restored! b))]
          [else
           (let ([finish (begin-attach! b)])
             (when finish (finish)))]))))

  (define (attach-open-buffers)
    (let ([started (filter values (map begin-attach! (files:buffers)))])
      (lambda ()
        (for-each
          (lambda (finish)
            (guard (c [(not (cancelled? c)) (report c)])
              (finish)))
          started))))

  (define (stop-attaching!)
    (for-each (lambda (a) (undo:install! (car a) #f (snapshot-version (cdr a)))) attaching)
    (set! attaching '()))

  (define (note-saved! b)
    (eq-hashtable-delete! silenced b)
    (let ([entry (eq-hashtable-ref logs b #f)] [path (logged-path b)])
      (cond
        [(and entry (equal? path (entry-path entry))) (note-pending-save! entry b)]
        [(and entry (not (entry-ready? entry))) (void)]
        [else
         (when entry
           (flush-log! entry)
           (eq-hashtable-delete! logs b))
         (when (and path (not (equal? path (eq-hashtable-ref unreadable-logs b #f))))
           (note-pending-save! (add-entry! b path (if entry (entry-saves entry) '()) #f #t) b))])))

  ;; The discarded edits stay a redo away and do not come back at the
  ;; next visit.
  (define (note-killed! b)
    (let ([entry (entry-of b)])
      (without-cancels
        (lambda ()
          (when entry
            (flush-log! entry)
            (when (entry-written? entry)
              (let* ([h (undo:history b)] [current (car h)] [saved (cadr h)])
                (when (and saved (not (eqv? saved current)))
                  (send! (list (vector 'append (entry-file entry) (list (list 'at saved)))))))))
          (eq-hashtable-delete! logs b)))))

  ;; The move goes through the writer's queue, so the log's earlier
  ;; writes land before it and its later ones after, at the new path.
  (define (note-rename! from to)
    (without-cancels
      (lambda ()
        (vector-for-each
          (lambda (entry)
            (let ([path (files:renamed-path (entry-path entry) from to)])
              (when path
                (entry-path-set! entry path)
                (entry-file-set! entry (log-file path)))))
          (hashtable-values logs))
        (let-values ([(buffers paths) (hashtable-entries unreadable-logs)])
          (vector-for-each
            (lambda (b path)
              (let ([new (files:renamed-path path from to)])
                (when new (eq-hashtable-set! unreadable-logs b new))))
            buffers paths))
        (send! (list (vector 'move (log-name from) (log-name to)))))))

  (define (compact! file)
    (let ([entry (find (lambda (entry) (equal? (entry-file entry) file)) (vector->list (hashtable-values logs)))])
      (when entry (entry-whole?-set! entry #t))))

  (define (ensure-log-folder!)
    (when (string=? (%log-folder) "")
      (let ([t (current-time 'time-utc)])
        (saved:set! %log-folder
          (format "~a/.local/share/tuna/undo-log/~a" (getenv "HOME")
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
    (unless (without-cancels
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

  (define (report-later c) (spawn-task (lambda (restore) (report c))))

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
              (spawn-task (lambda (restore) (compact! file))))
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
                    [(aside)
                     (attempt
                       (lambda ()
                         (let ([aside (set-log-aside! file)] [message (vector-ref item 2)] [path (vector-ref item 3)])
                           (hashtable-delete! sizes file)
                           (when aside
                             (spawn-task
                               (lambda (restore)
                                 (warn 'undo-log message (files:abbreviated-path path) (files:abbreviated-path aside))))))))]
                    [(delete) (attempt (lambda () (delete-log! file) (hashtable-delete! sizes file)))]
                    [(move)
                     (for-each (lambda (entry) (flush-appends! (car entry))) appends)
                     (hashtable-clear! sizes)
                     (attempt (lambda () (move-logs! file (vector-ref item 2))))])))))
        items)
      (for-each (lambda (entry) (flush-appends! (car entry))) (reverse appends))))

  (define (run-writer)
    (let loop ()
      (let ([items (take-work!)])
        (when items
          (write-round! items)
          (loop)))))

  (define (start-writer!) (fork-task (lambda (restore) (run-writer))))

  ;; Exit unloads this module too, so the wait is bounded: a round that
  ;; prints a huge edit could otherwise hold exit for seconds. A round
  ;; still running when the wait ends goes on, and can append to a log as
  ;; a reloaded instance's writer does.
  (define writer-wait 2)

  (define (stop-writer!)
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
        (warn 'undo-log "the log writer did not finish within ~a seconds; the edits it had not written are not in the logs"
              writer-wait))))

  (define (stop!)
    (stop-attaching!)
    (flush-logs!)
    (stop-writer!)))

(import %internals)

(ensure-log-folder!)
(start-writer!)
;; Ahead of other entries, whose edits would otherwise start a history of
;; their own in place of the log's.
(hooks:add! files:after-visit note-visit! -100)
(hooks:add! files:after-save note-saved!)
(hooks:add! files:after-revert note-saved!)
(hooks:add! files:unsaved-kept logged?)
(hooks:add! files:after-rename note-rename!)
(hooks:add! buffers:after-edit note-silent-edit!)
;; Ahead of undo's entry, which drops the history.
(hooks:add! buffers:killed note-killed! -100)
(advice-add! files:read-document read-with-log)
(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (call-as-owner %self (lambda () (guard (c [(not (cancelled? c)) (report c)]) (flush-logs!))))))
(on-unload stop!)
(let ([finish-attaching (attach-open-buffers)])
  (spawn-task (lambda (restore) (finish-attaching))))
