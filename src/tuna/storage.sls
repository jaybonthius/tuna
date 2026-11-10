(library (tuna storage)
  (export
    start-storage!
    saved-file
    read-saved-file
    check-accepts?
    report-rejection!
    reject-saved-value!
    write-saved-file!
    delete-saved-file!
    wait-for-saved-files!)
  (import (chezscheme)
          (only (tuna core changes) with-quit-safe-mutex)
          (only (tuna core definitions) report-safely)
          (only (tuna core main-thread) post-task! quit-condition?)
          (only (tuna plugin-manager) module-plugin-source) (tuna plain-data))

  (define saved-folder #f)

  (define (start-storage! folder)
    (set! saved-folder folder))

  ;; Each part becomes one file or folder name, and different parts give
  ;; different names: no part can hold a "/" or be "." or "..".
  (define (file-name-part s)
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

  (define (owner-source owner)
    (cond
      [(member owner '((init) (repl))) "user"]
      [(equal? owner '(tuna)) "tuna"]
      [else
       (let ([source (module-plugin-source owner)])
         (if (symbol? source) (symbol->string source) (file-name-part source)))]))

  (define (saved-file owner name)
    (format "~a/~a~{/~a~}/~a.ss" saved-folder (owner-source owner)
      (map (lambda (part) (file-name-part (symbol->string part))) owner)
      (file-name-part (symbol->string name))))

  ;; Invalid UTF-8 raises rather than reading as replacement characters, so
  ;; a damaged file is rejected instead of giving a different value. A file
  ;; that cannot be opened raises and stays in place, since the fault may
  ;; pass, as too many open files does.
  (define (read-only-datum file)
    (call-with-port
      (open-file-input-port file (file-options) (buffer-mode block)
        (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode raise)))
      (lambda (p)
        (guard (c [(or (lexical-violation? c) (i/o-decoding-error? c)) #f])
          (parameterize ([case-sensitive #t])
            (let ([v (get-datum p)])
              (and (not (eof-object? v)) (eof-object? (get-datum p)) (list v))))))))

  ;; A check that raises rejects the value, but a quit goes through, so a
  ;; check that never returns can be ended.
  (define (check-accepts? check v)
    (guard (c [(not (quit-condition? c)) #f])
      (check v)))

  (define (rejected-file file)
    (string-append file ".rejected"))

  (define (report-rejection! file reason)
    (report-safely
      (condition (make-warning) (make-who-condition 'define-saved)
        (make-message-condition (format "~a ~a; it is moved to ~a" file reason (rejected-file file))))))

  (define (reject! file reason)
    (report-rejection! file reason)
    (guard (c [#t (report-safely c)])
      (rename-file file (rejected-file file))))

  (define (read-saved-file file check)
    (and (file-exists? file)
         (let ([found (read-only-datum file)])
           (cond
             [(not found) (reject! file "cannot be read") #f]
             [(not (plain-data? (car found))) (reject! file "holds a value that is not plain data") #f]
             [(check-accepts? check (car found)) found]
             [else (reject! file "holds a value that fails its check") #f]))))

  ;; The printer's parameters are whatever the calling thread's code set;
  ;; the stored text must read back as the same value in a later process.
  ;; Plain data may share structure, which printed without labels can grow
  ;; exponentially.
  (define (saved-text v)
    (call-with-string-output-port
      (lambda (p)
        (parameterize ([print-graph #t] [print-level #f] [print-length #f] [print-radix 10]
                       [print-gensym #t] [print-char-name #f] [print-extended-identifiers #f])
          (write v p)
          (newline p)))))

  ;; Only a file's last state matters, so a file has at most one job
  ;; waiting.
  (define-record-type job
    (nongenerative)
    (sealed #t)
    (fields file bytes))

  (define writer-mutex (make-mutex))
  (define jobs-waiting (make-condition))
  (define writes-finished (make-condition))
  (define jobs '())
  (define writing? #f)
  (define writer-started? #f)
  (define failures '())

  ;; A file queued again goes to the back, so jobs run in the order they
  ;; were last queued.
  (define (queue-job! file bytes)
    (with-quit-safe-mutex writer-mutex
      (set! jobs (append (remp (lambda (j) (string=? (job-file j) file)) jobs)
                         (list (make-job file bytes))))
      (unless writer-started?
        (set! writer-started? #t)
        (fork-thread write-jobs))
      (condition-signal jobs-waiting)))

  ;; Serialized on the caller's thread, so the writer holds bytes that no
  ;; other code can change.
  (define (write-saved-file! file v)
    (queue-job! file (string->utf8 (saved-text v))))

  (define (delete-saved-file! file)
    (queue-job! file #f))

  ;; The copy is queued before the deletion, so a crash between them cannot
  ;; lose the value, and a write of the file already in flight lands first.
  (define (reject-saved-value! file v)
    (write-saved-file! (rejected-file file) v)
    (delete-saved-file! file))

  (define (next-job!)
    (with-mutex writer-mutex
      (let wait ()
        (cond
          [(pair? jobs)
           (let ([j (car jobs)])
             (set! jobs (cdr jobs))
             (set! writing? #t)
             j)]
          [else
           (set! writing? #f)
           (condition-broadcast writes-finished)
           (condition-wait jobs-waiting writer-mutex)
           (wait)]))))

  (define (write-jobs)
    (let loop ()
      (let ([j (next-job!)])
        (guard (c [#t (failed! c)])
          (if (job-bytes j)
              (replace-file! (job-file j) (job-bytes j))
              (let ([file (job-file j)])
                (guard (c [(not (file-exists? file #f)) (void)])
                  (delete-file file #t)))))
        (loop))))

  ;; Reported on the main thread, where report's advice runs; at exit the
  ;; queue no longer runs what is posted, so waiting reports them instead.
  (define (failed! c)
    (with-mutex writer-mutex
      (set! failures (cons c failures)))
    (post-task! report-failures! '(tuna) #f))

  (define (report-failures!)
    (for-each report-safely
      (reverse
        (with-quit-safe-mutex writer-mutex
          (let ([taken failures])
            (set! failures '())
            taken)))))

  (define (wait-for-saved-files!)
    (with-quit-safe-mutex writer-mutex
      (let wait ()
        (when (or writing? (pair? jobs))
          (condition-wait writes-finished writer-mutex)
          (wait))))
    (report-failures!))

  ;; Another Tuna may make the same folder at the same moment.
  (define (make-folders! path)
    (unless (file-directory? path)
      (make-folders! (path-parent path))
      (guard (c [(file-directory? path) (void)])
        (mkdir path))))

  ;; Without fsync a rename can reach the disk before the data it names, so
  ;; a crash could leave an empty or partial file in place of the old one.
  (define fsync
    (begin
      (load-shared-object #f)
      (foreign-procedure __collect_safe "fsync" (int) int)))

  ;; The temporary name carries the process id, since two Tunas may write
  ;; the same datum at once.
  (define (replace-file! file bytes)
    (make-folders! (path-parent file))
    (let ([temporary (format "~a.~a.new" file (get-process-id))])
      (guard (c [#t (delete-file temporary #f) (raise c)])
        (let ([p (open-file-output-port temporary (file-options no-fail))])
          (dynamic-wind
            void
            (lambda ()
              (put-bytevector p bytes)
              (flush-output-port p)
              (unless (fx= (fsync (port-file-descriptor p)) 0)
                (errorf 'set-saved! "cannot write ~a to disk" temporary)))
            (lambda () (close-port p))))
        (rename-file temporary file)))))
