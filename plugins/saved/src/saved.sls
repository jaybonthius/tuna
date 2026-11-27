#!tuna
(import (plugins) (plain-data))

;; stored is value as it was when set, and initial-copy initial as it was
;; when defined, in copies no other code holds, so the writer can print
;; them while the originals change in place.
(define-record-type (%saved %make-saved %saved?)
  (nongenerative)
  (sealed #t)
  (fields symbol file (mutable initial) (mutable initial-copy) (mutable check) (mutable value)
          (mutable stored)))

(define %by-procedure (make-weak-eq-hashtable))

;; Keyed by file, which names the source of the module's plugin, so a
;; fork's datum is another datum.
(define %states (make-hashtable string-hash string=?))

;; Other threads set and remove saved data; the mutex keeps each value and
;; the file queued for it in step.
(define %mutex (make-mutex))

(define (saved? v) (and (procedure? v) (hashtable-ref %by-procedure v #f) #t))

(define (%of who s)
  (or (and (procedure? s) (hashtable-ref %by-procedure s #f))
      (assertion-violation who "not saved data" s)))

(define (%check-valid who symbol check v)
  (unless (check v)
    (assertion-violation who (format "~s is not a valid value for ~s" v symbol))))

;; A check that raises rejects the value, but a cancel goes through, so a
;; check that never returns can be ended.
(define (%accepts? check v)
  (guard (c [(not (cancelled? c)) #f])
    (check v)))

(define %folder
  (let ([data (getenv "XDG_DATA_HOME")])
    (if (and data (> (string-length data) 0))
        (string-append data "/tuna/saved")
        (string-append (getenv "HOME") "/.local/share/tuna/saved"))))

;; Each part becomes one file or folder name, and different parts give
;; different names: no part can hold a "/" or be "." or "..".
(define (%file-name-part s)
  (let ([n (string-length s)])
    (call-with-string-output-port
      (lambda (p)
        (do ([i 0 (fx+ i 1)]) ((fx= i n))
          (let ([c (string-ref s i)])
            (case c
              [(#\/) (put-string p "%2F")]
              [(#\%) (put-string p "%25")]
              [(#\nul) (put-string p "%00")]
              [(#\.) (put-string p (if (fx= i 0) "%2E" "."))]
              [else (put-char p c)])))))))

(define (%owner-source owner)
  (if (eq? (module-owner (owner-name owner)) owner)
      (let ([source (plugins:module-source (owner-name owner))])
        (if (symbol? source) (symbol->string source) (%file-name-part source)))
      "user"))

(define (%file-for owner name)
  (format "~a/~a~{/~a~}/~a.ss" %folder (%owner-source owner)
    (map (lambda (part) (%file-name-part (symbol->string part))) (owner-name owner))
    (%file-name-part (symbol->string name))))

;; Invalid UTF-8 raises rather than reading as replacement characters, so a
;; damaged file is rejected instead of giving a different value. A file
;; that cannot be opened raises and stays in place, since the fault may
;; pass, as too many open files does.
(define (%read-only-datum file)
  (call-with-port
    (open-file-input-port file (file-options) (buffer-mode block)
      (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode raise)))
    (lambda (p)
      (guard (c [(or (lexical-violation? c) (i/o-decoding-error? c)) #f])
        (parameterize ([case-sensitive #t])
          (let ([v (get-datum p)])
            (and (not (eof-object? v)) (eof-object? (get-datum p)) (list v))))))))

(define (%rejected-file file) (string-append file ".rejected"))

(define (%report-rejection! file reason)
  (report (condition (make-warning) (make-who-condition 'saved:define-saved)
            (make-message-condition (format "~a ~a; it is moved to ~a" file reason (%rejected-file file))))))

(define (%reject! file reason)
  (%report-rejection! file reason)
  (guard (c [(i/o-error? c) (report c)])
    (rename-file file (%rejected-file file))))

(define (%read-saved-file file check)
  (and (file-exists? file)
       (let ([found (%read-only-datum file)])
         (cond
           [(not found) (%reject! file "cannot be read") #f]
           [(not (plain-data:plain-data? (car found))) (%reject! file "holds a value that is not plain data") #f]
           [(%accepts? check (car found)) found]
           [else (%reject! file "holds a value that fails its check") #f]))))

(define %main-thread (get-thread-id))

(define (%define-saved owner name initial check)
  (unless (eqv? (get-thread-id) %main-thread)
    (assertion-violation 'saved:define-saved "only the main thread makes changes"))
  (unless (procedure? check) (assertion-violation 'saved:define-saved "not a procedure" check))
  (let* ([symbol (if (eq? (module-owner (owner-name owner)) owner)
                     (string->symbol (format "~{~a~^/~}:~a" (owner-name owner) name))
                     name)]
         [initial-copy (plain-data:copy 'saved:define-saved initial)]
         [file (%file-for owner name)])
    (%check-valid 'saved:define-saved symbol check initial)
    (cond
      [(hashtable-ref %states file #f)
       => (lambda (st)
            (let-values ([(kept old-initial)
                          (with-mutex %mutex
                            (let ([old-initial (%saved-initial st)])
                              (%saved-initial-set! st initial)
                              (%saved-initial-copy-set! st initial-copy)
                              (%saved-check-set! st check)
                              (values (%saved-value st) old-initial)))])
              (unless (%accepts? check kept)
                (%reject-kept-value! st kept old-initial)))
            (%reader st))]
      [else
       (let* ([found (%read-saved-file file check)]
              [st (if found
                      (%make-saved symbol file initial initial-copy check
                        (plain-data:copy 'saved:define-saved (car found)) (car found))
                      (%make-saved symbol file initial initial-copy check initial initial-copy))])
         (hashtable-set! %states file st)
         (%reader st))])))

(define (%reader st)
  (case-lambda
    [() (%saved-value st)]
    [(v) (assertion-violation (%saved-symbol st) "saved data is set with saved:set!")]))

(define (%register! procedure owner name)
  (hashtable-set! %by-procedure procedure (hashtable-ref %states (%file-for owner name) #f)))

;; The check runs outside the mutex, so another thread may have set the
;; datum since; that value stays. A value that is still the initial one
;; holds nothing worth keeping, so it goes without a copy or a warning.
(define (%reject-kept-value! st kept old-initial)
  (let ([file (%saved-file st)])
    (when (with-mutex %mutex
            (and (eq? (%saved-value st) kept)
                 (let ([stored (%saved-stored st)])
                   (%reset-to-initial! st)
                   (cond
                     [(eq? kept old-initial) (%delete-saved-file! file) #f]
                     [else (%reject-saved-value! file stored) #t]))))
      (%report-rejection! file "holds a value that fails its check"))))

(define-syntax define-saved
  (syntax-rules ()
    [(_ id initial check)
     (begin
       (define-public id (%define-saved (current-owner) 'id initial check))
       (define-values () (begin (%register! id (current-owner) 'id) (values))))]))

;; Queued at once: the queue keeps one request per file, so a datum set
;; again before the writer takes it is written once.
(define (set! s v)
  (let* ([st (%of 'saved:set! s)] [stored (plain-data:copy 'saved:set! v)])
    (%check-valid 'saved:set! (%saved-symbol st) (%saved-check st) v)
    (with-mutex %mutex
      (%saved-value-set! st v)
      (%saved-stored-set! st stored)
      (%write-saved-file! (%saved-file st) stored))
    (void)))

(define (%reset-to-initial! st)
  (%saved-value-set! st (%saved-initial st))
  (%saved-stored-set! st (%saved-initial-copy st)))

(define (remove! s)
  (let ([st (%of 'saved:remove! s)])
    (with-mutex %mutex
      (%reset-to-initial! st)
      (%delete-saved-file! (%saved-file st)))
    (void)))

;;; The writer

;; Only a file's last state matters, so a file has at most one write
;; request waiting.
(define-record-type (%request %make-request %request?)
  (nongenerative)
  (sealed #t)
  (fields file delete? value))

(define %writer-mutex (make-mutex))
(define %requests-waiting (make-condition))
(define %requests (box '()))
(define %finishing? (box #f))

;; A file queued again goes to the back, so requests run in the order they
;; were last queued.
(define (%queue-request! file delete? v)
  (with-mutex %writer-mutex
    (set-box! %requests (append (remp (lambda (r) (string=? (%request-file r) file)) (unbox %requests))
                                (list (%make-request file delete? v))))
    (condition-signal %requests-waiting)))

;; Printed on the writer's thread, so v must be a value no other code
;; changes, such as one from plain-data:copy.
(define (%write-saved-file! file v) (%queue-request! file #f v))

(define (%delete-saved-file! file) (%queue-request! file #t #f))

;; The copy is queued before the deletion, so a crash between them cannot
;; lose the value, and a write of the file already in flight lands first.
(define (%reject-saved-value! file v)
  (%write-saved-file! (%rejected-file file) v)
  (%delete-saved-file! file))

(define (%next-request!)
  (with-mutex %writer-mutex
    (let wait ()
      (cond
        [(pair? (unbox %requests))
         (let ([r (car (unbox %requests))])
           (set-box! %requests (cdr (unbox %requests)))
           r)]
        [(unbox %finishing?) #f]
        [else (condition-wait %requests-waiting %writer-mutex) (wait)]))))

;; Reported on the main thread, where report's advice runs. Once exit has
;; begun no task starts but a clean-up task, so each failure waits here
;; until a task reports it, and the unload action reports what is left.
(define %unreported (box '()))

(define (%take-unreported! c)
  (with-mutex %writer-mutex
    (and (memq c (unbox %unreported))
         (begin (set-box! %unreported (remq c (unbox %unreported))) #t))))

(define (%write-requests restore)
  (let loop ()
    (let ([r (%next-request!)])
      (when r
        (guard (c [(cancelled? c) (raise c)]
                  [#t (with-mutex %writer-mutex (set-box! %unreported (cons c (unbox %unreported))))
                      (spawn-task (lambda (restore) (when (%take-unreported! c) (report c))))])
          (let ([file (%request-file r)])
            (if (%request-delete? r)
                (guard (c [(not (file-exists? file #f)) (void)])
                  (delete-file file #t))
                (%replace-file! file (%request-value r)))))
        (loop)))))

;; Without fsync a rename can reach the disk before the data it names, so
;; a crash could leave an empty or partial file in place of the old one.
(define %fsync
  (begin
    (load-shared-object #f)
    (foreign-procedure __collect_safe "fsync" (int) int)))

;; The printer's parameters are whatever the thread's code set; the stored
;; text must read back as the same value in a later process. Plain data may
;; share structure, which printed without labels can grow exponentially.
(define (%write-saved-value v p)
  (parameterize ([print-graph #t] [print-level #f] [print-length #f] [print-radix 10]
                 [print-gensym #t] [print-char-name #f] [print-extended-identifiers #f])
    (write v p)
    (newline p)))

;; Another thread, or another Tuna, may make the same folder at the same
;; moment.
(define (%make-folders! path)
  (unless (or (string=? path "") (file-directory? path))
    (%make-folders! (path-parent path))
    (guard (c [(and (i/o-error? c) (file-directory? path)) (void)])
      (mkdir path))))

;; The temporary name carries the process id, since two Tunas may write the
;; same datum at once.
(define (%replace-file! file v)
  (%make-folders! (path-parent file))
  (let ([temporary (format "~a.~a.new" file (get-process-id))])
    (guard (c [#t (delete-file temporary #f) (raise c)])
      (let ([p (open-file-output-port temporary (file-options no-fail) (buffer-mode block)
                 (make-transcoder (utf-8-codec) (eol-style none)))])
        (dynamic-wind
          void
          (lambda ()
            (%write-saved-value v p)
            (flush-output-port p)
            (unless (fx= (%fsync (port-file-descriptor p)) 0)
              (errorf 'saved:set! "cannot write ~a to disk" temporary)))
          (lambda () (close-port p))))
      (rename-file temporary file))))

(define %writer (fork-task %write-requests))

;; The writer still runs while this action does, so the last batch lands
;; before the kernel stops it.
(on-unload
  (lambda ()
    (with-mutex %writer-mutex
      (set-box! %finishing? #t)
      (condition-signal %requests-waiting))
    (join-task %writer)
    (for-each (lambda (c) (when (%take-unreported! c) (report c))) (reverse (unbox %unreported)))))
