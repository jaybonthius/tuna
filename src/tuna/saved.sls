(library (tuna saved)
  (export
    define-saved
    set-saved!
    remove-saved!
    saved?
    finish-saved-data!)
  (import (chezscheme) (tuna core changes) (tuna core definitions)
          (only (tuna core main-thread) post-task!) (tuna plain-data) (tuna storage))

  (define-record-type saved-state
    (nongenerative)
    (sealed #t)
    (fields symbol file (mutable initial) (mutable check) (mutable value) (mutable pending?)
            (mutable procedure)))

  (define (saved? v)
    (and (wrapper-procedure? v) (saved-state? (wrapper-procedure-data v))))

  (define (saved-state-of who s)
    (unless (saved? s)
      (assertion-violation who "not saved data" s))
    (wrapper-procedure-data s))

  (define (check-value who symbol check v)
    (unless (plain-data? v)
      (assertion-violation who "not plain data" v))
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
    (let* ([owner (current-owner)] [symbol (definition-symbol owner name)])
      (check-value 'define-saved symbol check initial)
      (let ([file (saved-file owner name)])
        (cond
          [(hashtable-ref saved-states file #f)
           => (lambda (st)
                (let-values ([(kept old-initial)
                              (with-quit-safe-mutex saved-mutex
                                (let ([old-initial (saved-state-initial st)])
                                  (saved-state-initial-set! st initial)
                                  (saved-state-check-set! st check)
                                  (values (saved-state-value st) old-initial)))])
                  (unless (check-accepts? check kept)
                    (reject-kept-value! st kept old-initial)))
                (saved-state-procedure st))]
          [else
           (let* ([stored (read-saved-file file check)]
                  [st (make-saved-state symbol file initial check (if stored (car stored) initial) #f #f)]
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
                   (begin
                     (saved-state-value-set! st (saved-state-initial st))
                     (drop-pending! st)
                     (cond
                       [(eq? kept old-initial) (delete-saved-file! file) #f]
                       [else (reject-saved-value! file kept) #t]))))
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
    (let ([st (saved-state-of 'set-saved! s)])
      (check-value 'set-saved! (saved-state-symbol st) (saved-state-check st) v)
      (with-quit-safe-mutex saved-mutex
        (saved-state-value-set! st v)
        (unless (saved-state-pending? st)
          (saved-state-pending?-set! st #t)
          (set! pending (cons st pending))
          (unless write-posted?
            (set! write-posted? #t)
            (post-task! write-pending! (find-owner '(tuna)) #f))))
      (void)))

  (define (drop-pending! st)
    (when (saved-state-pending? st)
      (saved-state-pending?-set! st #f)
      (set! pending (remq st pending))))

  (define (remove-saved! s)
    (let ([st (saved-state-of 'remove-saved! s)])
      (with-quit-safe-mutex saved-mutex
        (saved-state-value-set! st (saved-state-initial st))
        (drop-pending! st)
        (delete-saved-file! (saved-state-file st)))
      (void)))

  ;; Values are serialized under the mutex, so a removal on another thread
  ;; cannot slip between serializing a value and queueing its file. A value
  ;; changed in place since it was set may no longer be plain data, and
  ;; printing it can raise.
  (define (write-pending!)
    (for-each report-safely
      (reverse
        (with-quit-safe-mutex saved-mutex
          (let ([states (reverse pending)])
            (set! pending '())
            (set! write-posted? #f)
            (fold-left
              (lambda (failures st)
                (saved-state-pending?-set! st #f)
                (guard (c [#t (cons c failures)])
                  (write-saved-file! (saved-state-file st) (saved-state-value st))
                  failures))
              '()
              states))))))

  (define (finish-saved-data!)
    (write-pending!)
    (wait-for-saved-files!)))
