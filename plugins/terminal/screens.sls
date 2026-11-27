(library (terminal screens)
  (export keep-screen! take-screen write-screen! delete-screen! wait-for-writes take-write-failures
          read-screen)
  (import (chezscheme))

;; Chez creates this library once per process, so a terminal's screen
  ;; kept here outlives a reload of the plugin, which reads it back
  ;; instead of its file. Only the main thread keeps and takes screens.
  (define kept (make-hashtable string-hash string=?))

  (define (keep-screen! id snapshot offset)
    (hashtable-set! kept id (cons snapshot offset)))

  (define (take-screen id)
    (let ([screen (hashtable-ref kept id #f)])
      (hashtable-delete! kept id)
      screen))

  ;; Writes are queued for one thread, so the main thread never waits on
  ;; the disk except, bounded, while the plugin unloads.
  (define queue '())
  (define writing? #f)
  (define failures '())
  (define queue-mutex (make-mutex))
  (define queue-ready (make-condition))

  (define busy (list 'busy))

  ;; A cancel can land anywhere in code on the main thread, so the main
  ;; thread holds the mutex only with interrupts disabled. A blocked
  ;; acquire with interrupts disabled would keep a collection waiting for
  ;; the main thread, so it only tries the mutex, which the writer holds
  ;; for a few instructions at a time.
  (define-syntax with-queue-mutex-on-main-thread
    (syntax-rules ()
      [(_ e1 e2 ...)
       (let retry ()
         (let ([v (with-interrupts-disabled
                    (if (mutex-acquire queue-mutex #f)
                        (let ([v (begin e1 e2 ...)])
                          (mutex-release queue-mutex)
                          v)
                        busy))])
           (if (eq? v busy) (retry) v)))]))

  (define (queue! job)
    (with-queue-mutex-on-main-thread
      (set! queue (append queue (list job)))
      (condition-signal queue-ready)))

  (define (write-screen! path snapshot offset) (queue! (vector path snapshot offset)))

  (define (delete-screen! path) (queue! (vector path #f #f)))

  ;; The writer cannot report, as it acts for no module; the plugin
  ;; reports what failed when it next waits for the writes.
  (define (take-write-failures)
    (with-queue-mutex-on-main-thread
      (let ([taken failures])
        (set! failures '())
        taken)))

  ;; Waiting on a condition would hold the mutex where a cancel can land,
  ;; so the main thread looks again every few milliseconds.
  (define (wait-for-writes seconds)
    (let ([deadline (add-duration (current-time 'time-monotonic)
                      (make-time 'time-duration (exact (floor (* (- seconds (floor seconds)) 1e9)))
                                 (exact (floor seconds))))]
          [pause (make-time 'time-duration 10000000 0)])
      (let loop ()
        (cond
          [(with-queue-mutex-on-main-thread (and (null? queue) (not writing?))) #t]
          [(time>=? (current-time 'time-monotonic) deadline) #f]
          [else (sleep pause) (loop)]))))

  (define (write-queued!)
    (let loop ()
      (let ([job (with-mutex queue-mutex
                   (let wait ()
                     (cond
                       [(pair? queue)
                        (let ([job (car queue)])
                          (set! queue (cdr queue))
                          (set! writing? #t)
                          job)]
                       [else
                        (set! writing? #f)
                        (condition-wait queue-ready queue-mutex)
                        (wait)])))])
        (guard (c [#t (with-mutex queue-mutex (set! failures (cons c failures)))])
          (if (vector-ref job 1)
              (write-file! (vector-ref job 0) (vector-ref job 1) (vector-ref job 2))
              (when (file-exists? (vector-ref job 0)) (delete-file (vector-ref job 0)))))
        (loop))))

  (define (make-folders! folder)
    (unless (or (string=? folder "") (file-directory? folder))
      (make-folders! (path-parent folder))
      (mkdir folder #o700)))

  ;; The scrollback can hold secrets, so the file is the user's alone,
  ;; and it is renamed into place so a crash never leaves half of one.
  (define (write-file! path snapshot offset)
    (make-folders! (path-parent path))
    (let ([temporary (string-append path ".new")])
      (when (file-exists? temporary) (delete-file temporary))
      (call-with-port (open-file-output-port temporary (file-options no-fail))
        (lambda (p)
          (chmod temporary #o600)
          (let ([header (make-bytevector 8)])
            (bytevector-u64-set! header 0 offset (endianness little))
            (put-bytevector p header))
          (put-bytevector p snapshot)))
      (rename-file temporary path)))

  (define (read-screen path)
    (and (file-exists? path)
         (guard (c [(i/o-error? c) #f])
           (let ([bytes (call-with-port (open-file-input-port path) get-bytevector-all)])
             (and (bytevector? bytes)
                  (fx> (bytevector-length bytes) 8)
                  (let ([snapshot (make-bytevector (fx- (bytevector-length bytes) 8))])
                    (bytevector-copy! bytes 8 snapshot 0 (bytevector-length snapshot))
                    (cons snapshot (bytevector-u64-ref bytes 0 (endianness little)))))))))

  (fork-thread write-queued!))
