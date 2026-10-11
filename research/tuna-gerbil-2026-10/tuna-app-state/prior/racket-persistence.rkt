#lang racket/base

(require racket/file
         racket/list
         racket/match
         (prefix-in layout: "layout.rkt")
         (prefix-in state: "state.rkt"))

(provide load-editor-state
         write-editor-state
         start-snapshotter
         request-snapshot!
         stop-snapshotter!)

(struct exn:fail:state-file exn:fail ())
(struct snapshotter (path lock pending stopping? wake-armed? wake worker-box write-state final-error))

(define current-state-file-version 2)

(define (raise-state-file-error path message . arguments)
  (raise
    (exn:fail:state-file
      (format "load-editor-state: ~a\n  path: ~a"
              (apply format message arguments)
              path)
      (current-continuation-marks))))

(define (with-snapshotter-lock snapshotter-instance thunk)
  (dynamic-wind
    (lambda () (semaphore-wait (snapshotter-lock snapshotter-instance)))
    thunk
    (lambda () (semaphore-post (snapshotter-lock snapshotter-instance)))))

(define (layout-child->datum child)
  `(layout-child ,(layout:layout-child-measure child)
                 ,(layout-item->datum (layout:layout-child-child child))))

(define (layout-item->datum item)
  (cond
    [(layout:layout-leaf? item)
     `(layout-leaf ,(layout:layout-leaf-id item)
                   ,(layout:layout-leaf-view-id item))]
    [else
     `(layout-node ,(layout:layout-node-id item)
                   ,(layout:layout-node-direction item)
                   ,(layout:layout-node-tiling item)
                   ,(layout:layout-node-scroll-anchor-id item)
                   ,@(for/list ([child (in-list (layout:layout-node-children item))])
                       (layout-child->datum child)))]))

(define (layout-tree->datum tree)
  `(layout-tree ,(layout:layout-tree-id tree)
                ,(layout-item->datum (layout:layout-tree-root tree))))

(define (frame->datum item)
  `(frame ,(layout:frame-id item)
          ,(layout:frame-layout-tree-id item)
          ,(layout:frame-layout-node-id item)
          ,(layout:frame-active-leaf-id item)))

(define (session->datum item)
  `(session ,(layout:session-id item)
            ,(layout:session-active-frame-id item)
            (layout-trees
              ,@(for/list ([id (in-list (sort (hash-keys (layout:session-layout-trees item)) <))])
                  (layout-tree->datum (hash-ref (layout:session-layout-trees item) id))))
            (frames
              ,@(for/list ([id (in-list (sort (hash-keys (layout:session-frames item)) <))])
                  (frame->datum (hash-ref (layout:session-frames item) id))))))

(define (state->datum editor-state)
  `(tuna-state
     (version ,current-state-file-version)
     (state
       (next-ids
         (buffer ,(state:editor-state-next-buffer-id editor-state))
         (view ,(state:editor-state-next-view-id editor-state))
         (session ,(state:editor-state-next-session-id editor-state))
         (frame ,(state:editor-state-next-frame-id editor-state))
         (layout-tree ,(state:editor-state-next-layout-tree-id editor-state))
         (layout-item ,(state:editor-state-next-layout-item-id editor-state)))
       (buffers
         ,@(for/list ([id (in-list (sort (hash-keys (state:editor-state-buffers editor-state)) <))])
             (define buffer (hash-ref (state:editor-state-buffers editor-state) id))
             `(buffer ,id ,(state:buffer-file buffer))))
       (views
         ,@(for/list ([id (in-list (sort (hash-keys (state:editor-state-views editor-state)) <))])
             (define view (hash-ref (state:editor-state-views editor-state) id))
             `(view ,id ,(state:view-buffer-id view))))
       (sessions
         ,@(for/list ([id (in-list (sort (hash-keys (state:editor-state-sessions editor-state)) <))])
             (session->datum (hash-ref (state:editor-state-sessions editor-state) id)))))))

(define (write-editor-state path editor-state)
  (state:validate-editor-state editor-state)
  (call-with-atomic-output-file
    path
    (lambda (out _temporary-path)
      (parameterize ([print-graph #f]
                     [print-struct #f])
        (write (state->datum editor-state) out)
        (newline out)
        (flush-output out)))))

(define (read-state-datum path)
  (call-with-input-file
    path
    (lambda (in)
      (parameterize ([read-accept-reader #f]
                     [read-accept-lang #f]
                     [read-accept-compiled #f]
                     [read-accept-graph #f]
                     [current-readtable #f])
        (define datum (read in))
        (when (eof-object? datum)
          (raise-state-file-error path "missing state datum"))
        (unless (eof-object? (read in))
          (raise-state-file-error path "expected exactly one state datum"))
        datum))))

(define (require-list path value description)
  (unless (list? value)
    (raise-state-file-error path "invalid ~a" description))
  value)

(define (records->hash path records id-of description)
  (define ids (map id-of records))
  (unless (= (length ids) (length (remove-duplicates ids)))
    (raise-state-file-error path "duplicate ~a entry" description))
  (for/hash ([record (in-list records)])
    (values (id-of record) record)))

(define (decode-buffers path entries)
  (define records
    (for/list ([entry (in-list (require-list path entries "buffers"))])
      (match entry
        [`(buffer ,id ,file)
         (unless (or (string? file) (not file))
           (raise-state-file-error path "invalid buffer file"))
         (state:buffer id file)]
        [_ (raise-state-file-error path "invalid buffer entry")])))
  (records->hash path records state:buffer-id "buffer"))

(define (decode-views path entries)
  (define records
    (for/list ([entry (in-list (require-list path entries "views"))])
      (match entry
        [`(view ,id ,buffer-id) (state:view id buffer-id 0)]
        [_ (raise-state-file-error path "invalid view entry")])))
  (records->hash path records state:view-id "view"))

(define (decode-layout-child path entry)
  (match entry
    [`(layout-child ,measure ,child)
     (layout:layout-child measure (decode-layout-item path child))]
    [_ (raise-state-file-error path "invalid layout child entry")]))

(define (decode-layout-item path entry)
  (match entry
    [`(layout-leaf ,id ,view-id) (layout:layout-leaf id view-id)]
    [`(layout-node ,id ,direction ,tiling ,scroll-anchor-id . ,children)
     (layout:layout-node id
                         direction
                         tiling
                         scroll-anchor-id
                         (for/list ([child (in-list (require-list path children "layout node children"))])
                           (decode-layout-child path child)))]
    [_ (raise-state-file-error path "invalid layout item entry")]))

(define (decode-layout-trees path entries)
  (define records
    (for/list ([entry (in-list (require-list path entries "layout trees"))])
      (match entry
        [`(layout-tree ,id ,root)
         (layout:layout-tree id (decode-layout-item path root))]
        [_ (raise-state-file-error path "invalid layout tree entry")])))
  (records->hash path records layout:layout-tree-id "layout tree"))

(define (decode-frames path entries)
  (define records
    (for/list ([entry (in-list (require-list path entries "frames"))])
      (match entry
        [`(frame ,id ,tree-id ,node-id ,leaf-id)
         (layout:frame id tree-id node-id leaf-id)]
        [_ (raise-state-file-error path "invalid frame entry")])))
  (records->hash path records layout:frame-id "frame"))

(define (decode-sessions path entries)
  (define records
    (for/list ([entry (in-list (require-list path entries "sessions"))])
      (match entry
        [`(session ,id ,active-frame-id
                   (layout-trees . ,layout-trees)
                   (frames . ,frames))
         (layout:session id
                         (decode-layout-trees path layout-trees)
                         (decode-frames path frames)
                         active-frame-id)]
        [_ (raise-state-file-error path "invalid session entry")])))
  (records->hash path records layout:session-id "session"))

(define (decode-state path state-datum)
  (match state-datum
    [`((next-ids
         (buffer ,next-buffer-id)
         (view ,next-view-id)
         (session ,next-session-id)
         (frame ,next-frame-id)
         (layout-tree ,next-layout-tree-id)
         (layout-item ,next-layout-item-id))
       (buffers . ,buffers)
       (views . ,views)
       (sessions . ,sessions))
     (state:make-validated-editor-state
       next-buffer-id
       (decode-buffers path buffers)
       next-view-id
       (decode-views path views)
       next-session-id
       (decode-sessions path sessions)
       next-frame-id
       next-layout-tree-id
       next-layout-item-id)]
    [_ (raise-state-file-error path "invalid state")]))

(define (decode-state-datum path datum)
  (match datum
    [`(tuna-state (version ,version) (state . ,state-datum))
     (unless (and (exact-integer? version)
                  (= version current-state-file-version))
       (raise-state-file-error path "unsupported state-file version ~a" version))
     (decode-state path state-datum)]
    [_ (raise-state-file-error path "invalid state-file header")]))

(define (load-editor-state path)
  (cond
    [(file-exists? path)
     (with-handlers ([exn:fail:state-file? raise]
                     [exn:fail?
                      (lambda (exception)
                        (raise-state-file-error path "invalid state: ~a"
                                                (exn-message exception)))])
       (decode-state-datum path (read-state-datum path)))]
    [else
     (make-parent-directory* path)
     (write-editor-state path state:empty-editor-state)
     state:empty-editor-state]))

(define (signal-snapshotter! snapshotter-instance)
  (with-snapshotter-lock
    snapshotter-instance
    (lambda ()
      (unless (unbox (snapshotter-wake-armed? snapshotter-instance))
        (set-box! (snapshotter-wake-armed? snapshotter-instance) #t)
        (semaphore-post (snapshotter-wake snapshotter-instance))))))

(define (mark-wakeup-consumed! snapshotter-instance)
  (with-snapshotter-lock
    snapshotter-instance
    (lambda ()
      (set-box! (snapshotter-wake-armed? snapshotter-instance) #f))))

(define (snapshotter-is-stopping? snapshotter-instance)
  (with-snapshotter-lock snapshotter-instance
                         (lambda ()
                           (unbox (snapshotter-stopping? snapshotter-instance)))))

(define (take-pending-state! snapshotter-instance)
  (with-snapshotter-lock
    snapshotter-instance
    (lambda ()
      (define pending (unbox (snapshotter-pending snapshotter-instance)))
      (set-box! (snapshotter-pending snapshotter-instance) #f)
      pending)))

(define (restore-pending-state! snapshotter-instance failed-state)
  (with-snapshotter-lock
    snapshotter-instance
    (lambda ()
      (unless (unbox (snapshotter-pending snapshotter-instance))
        (set-box! (snapshotter-pending snapshotter-instance) failed-state)))))

(define (wait-for-delay-or-stop! snapshotter-instance seconds)
  (define deadline (+ (current-inexact-milliseconds) (* seconds 1000)))
  (let loop ()
    (cond
      [(snapshotter-is-stopping? snapshotter-instance) #t]
      [else
       (define remaining (/ (- deadline (current-inexact-milliseconds)) 1000.0))
       (cond
         [(<= remaining 0) #f]
         [(sync/timeout remaining (snapshotter-wake snapshotter-instance))
          (mark-wakeup-consumed! snapshotter-instance)
          (loop)]
         [else #f])])))

(define (write-pending-state! snapshotter-instance editor-state)
  (with-handlers ([exn?
                   (lambda (exception)
                     (eprintf "tuna: failed to snapshot state to ~a: ~a\n"
                              (snapshotter-path snapshotter-instance)
                              (exn-message exception))
                     #f)])
    ((snapshotter-write-state snapshotter-instance)
     (snapshotter-path snapshotter-instance)
     editor-state)
    #t))

(define (finish-snapshotter! snapshotter-instance)
  (define final-state (take-pending-state! snapshotter-instance))
  (when final-state
    (with-handlers ([exn?
                     (lambda (exception)
                       (set-box! (snapshotter-final-error snapshotter-instance) exception))])
      ((snapshotter-write-state snapshotter-instance)
       (snapshotter-path snapshotter-instance)
       final-state))))

(define (snapshotter-loop snapshotter-instance)
  (let loop ([delay #f])
    (cond
      [(not delay)
       (semaphore-wait (snapshotter-wake snapshotter-instance))
       (mark-wakeup-consumed! snapshotter-instance)
       (loop 1)]
      [(wait-for-delay-or-stop! snapshotter-instance delay)
       (finish-snapshotter! snapshotter-instance)]
      [else
       (define pending-state (take-pending-state! snapshotter-instance))
       (cond
         [(not pending-state) (loop #f)]
         [(write-pending-state! snapshotter-instance pending-state) (loop #f)]
         [else
          (restore-pending-state! snapshotter-instance pending-state)
          (loop 5)])])))

(define (start-snapshotter path #:write-state [write-state write-editor-state])
  (define result
    (snapshotter path
                 (make-semaphore 1)
                 (box #f)
                 (box #f)
                 (box #f)
                 (make-semaphore 0)
                 (box #f)
                 write-state
                 (box #f)))
  (define worker
    (thread (lambda () (snapshotter-loop result))))
  (set-box! (snapshotter-worker-box result) worker)
  result)

(define (request-snapshot! snapshotter-instance editor-state)
  (state:validate-editor-state editor-state)
  (with-snapshotter-lock
    snapshotter-instance
    (lambda ()
      (unless (unbox (snapshotter-stopping? snapshotter-instance))
        (set-box! (snapshotter-pending snapshotter-instance) editor-state))))
  (signal-snapshotter! snapshotter-instance)
  (void))

(define (stop-snapshotter! snapshotter-instance final-state)
  (state:validate-editor-state final-state)
  (with-snapshotter-lock
    snapshotter-instance
    (lambda ()
      (set-box! (snapshotter-stopping? snapshotter-instance) #t)
      (set-box! (snapshotter-pending snapshotter-instance) final-state)))
  (signal-snapshotter! snapshotter-instance)
  (thread-wait (unbox (snapshotter-worker-box snapshotter-instance)))
  (define final-error (unbox (snapshotter-final-error snapshotter-instance)))
  (when final-error
    (raise final-error))
  (void))

