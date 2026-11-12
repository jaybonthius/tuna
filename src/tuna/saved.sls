(library (tuna saved)
  (export
    define-saved
    set-saved!
    remove-saved!
    saved?
    finish-saved-data!)
  (import (chezscheme) (tuna core changes) (tuna core definitions)
          (only (tuna core main-thread) post-task!) (tuna plain-data) (tuna storage))

  ;; stored is value as it was when set, and initial-copy initial as it
  ;; was when defined, in copies no other code holds, so the writer can
  ;; print them while the originals change in place.
  (define-record-type saved-state
    (nongenerative)
    (sealed #t)
    (fields symbol file (mutable initial) (mutable initial-copy) (mutable check) (mutable value)
            (mutable stored) (mutable pending?) (mutable procedure)))

  (define (saved? v)
    (and (wrapper-procedure? v) (saved-state? (wrapper-procedure-data v))))

  (define (saved-state-of who s)
    (unless (saved? s)
      (assertion-violation who "not saved data" s))
    (wrapper-procedure-data s))

  (define (check-valid who symbol check v)
    (unless (check v)
      (assertion-violation who (format "~s is not a valid value for ~s" v symbol))))

  ;; Other threads set and remove saved data; the mutex keeps each value
  ;; and the files waiting to be written in step.
  (define saved-mutex (make-mutex))
  (define pending '())
  (define write-posted? #f)

  ;; Keyed by file, which names the source of the module's plugin, so a
  ;; fork's datum is another datum.
  (define saved-states (make-hashtable string-hash string=?))

  (define (make-saved name initial check)
    (check-main-thread 'define-saved)
    (unless (procedure? check)
      (assertion-violation 'define-saved "not a procedure" check))
    (let* ([owner (current-owner)] [symbol (definition-symbol owner name)]
           [initial-copy (plain-data-copy 'define-saved initial)])
      (check-valid 'define-saved symbol check initial)
      (let ([file (saved-file owner name)])
        (cond
          [(hashtable-ref saved-states file #f)
           => (lambda (st)
                (let-values ([(kept old-initial)
                              (with-quit-safe-mutex saved-mutex
                                (let ([old-initial (saved-state-initial st)])
                                  (saved-state-initial-set! st initial)
                                  (saved-state-initial-copy-set! st initial-copy)
                                  (saved-state-check-set! st check)
                                  (values (saved-state-value st) old-initial)))])
                  (unless (check-accepts? check kept)
                    (reject-kept-value! st kept old-initial)))
                (saved-state-procedure st))]
          [else
           (let* ([found (read-saved-file file check)]
                  [st (if found
                          (make-saved-state symbol file initial initial-copy check
                            (plain-data-copy 'define-saved (car found)) (car found) #f #f)
                          (make-saved-state symbol file initial initial-copy check
                            initial initial-copy #f #f))]
                  [s (make-wrapper-procedure
                       (case-lambda
                         [() (saved-state-value st)]
                         [(v) (assertion-violation symbol "saved data is set with set-saved!")])
                       3
                       st)])
             (saved-state-procedure-set! st s)
             (hashtable-set! saved-states file st)
             s)]))))

  ;; The check runs outside the mutex, so another thread may have set the
  ;; datum since; that value stays. A value that is still the initial one
  ;; holds nothing worth keeping, so it goes without a copy or a warning.
  (define (reject-kept-value! st kept old-initial)
    (let ([file (saved-state-file st)])
      (when (with-quit-safe-mutex saved-mutex
              (and (eq? (saved-state-value st) kept)
                   (let ([stored (saved-state-stored st)])
                     (reset-to-initial! st)
                     (drop-pending! st)
                     (cond
                       [(eq? kept old-initial) (delete-saved-file! file) #f]
                       [else (reject-saved-value! file stored) #t]))))
        (report-rejection! file "holds a value that fails its check"))))

  (define-syntax define-saved
    (lambda (x)
      (syntax-case x ()
        [(_ id initial check)
         (identifier? #'id)
         #'(define-exported id (make-saved 'id initial check))])))

  ;; Posted, so the file is written once after the code running on the
  ;; main thread finishes, however often that code sets the datum.
  (define (set-saved! s v)
    (let* ([st (saved-state-of 'set-saved! s)] [stored (plain-data-copy 'set-saved! v)])
      (check-valid 'set-saved! (saved-state-symbol st) (saved-state-check st) v)
      (with-quit-safe-mutex saved-mutex
        (saved-state-value-set! st v)
        (saved-state-stored-set! st stored)
        (unless (saved-state-pending? st)
          (saved-state-pending?-set! st #t)
          (set! pending (cons st pending))
          (unless write-posted?
            (set! write-posted? #t)
            (post-task! write-pending! (find-owner '(tuna))))))
      (void)))

  (define (reset-to-initial! st)
    (saved-state-value-set! st (saved-state-initial st))
    (saved-state-stored-set! st (saved-state-initial-copy st)))

  (define (drop-pending! st)
    (when (saved-state-pending? st)
      (saved-state-pending?-set! st #f)
      (set! pending (remq st pending))))

  (define (remove-saved! s)
    (let ([st (saved-state-of 'remove-saved! s)])
      (with-quit-safe-mutex saved-mutex
        (reset-to-initial! st)
        (drop-pending! st)
        (delete-saved-file! (saved-state-file st)))
      (void)))

  ;; Queued under the mutex, so a removal on another thread cannot slip
  ;; between taking a value and queueing its file.
  (define (write-pending!)
    (with-quit-safe-mutex saved-mutex
      (for-each
        (lambda (st)
          (saved-state-pending?-set! st #f)
          (write-saved-file! (saved-state-file st) (saved-state-stored st)))
        (reverse pending))
      (set! pending '())
      (set! write-posted? #f)))

  (define (finish-saved-data!)
    (write-pending!)
    (wait-for-saved-files!)))
