(library (undo-log disk)
  (export read-log records->bytes append-log! replace-log! set-log-aside! delete-log! move-logs! log-size)
  (import (chezscheme) (document))

  (define c-fsync
    (begin
      (load-shared-object #f)
      (foreign-procedure __collect_safe "fsync" (int) int)))
  (define c-fdatasync (foreign-procedure __collect_safe "fdatasync" (int) int))
  (define c-open (foreign-procedure "open" (string int) int))
  (define c-close (foreign-procedure "close" (int) int))

  (define (count? v) (and (fixnum? v) (fx>= v 0)))

  (define (edit-datum e)
    (vector (vector-ref e 0) (document:datums (vector-ref e 1)) (document:datums (vector-ref e 2))))

  (define (record-datum r)
    (case (car r)
      [(group) (append (list-head r 5) (map edit-datum (list-tail r 5)))]
      [(more) (cons* 'more (cadr r) (map edit-datum (cddr r)))]
      [else r]))

  ;; A record must read back as the datum written, whatever the printer
  ;; parameters of the thread printing it.
  (define (records->bytes records)
    (call-with-bytevector-output-port
      (lambda (p)
        (parameterize ([print-graph #f] [print-level #f] [print-length #f] [print-radix 10]
                       [print-gensym #t] [print-char-name #f] [print-extended-identifiers #f]
                       [print-vector-length #f] [print-precision #f] [print-brackets #f])
          (for-each (lambda (r) (write (record-datum r) p) (newline p)) records)))
      (make-transcoder (utf-8-codec) (eol-style none))))

  ;; Documents never change, so every empty one read is the same, and
  ;; typing, which removes nothing, builds one document per edit.
  (define empty (document:from-datum))

  (define (datums-document ds)
    (if (null? ds) empty (apply document:from-datum ds)))

  (define (datum-edit v)
    (and (vector? v) (fx= (vector-length v) 3) (count? (vector-ref v 0))
         (list? (vector-ref v 1)) (list? (vector-ref v 2))
         (vector (vector-ref v 0) (datums-document (vector-ref v 1)) (datums-document (vector-ref v 2)))))

  ;; The datum read is fresh, so its changes become edits in place.
  (define (edits! ds)
    (let loop ([ds ds])
      (or (null? ds)
          (let ([e (datum-edit (car ds))])
            (and e
                 (begin
                   (set-car! ds e)
                   (loop (cdr ds))))))))

  (define (count-list? v) (and (list? v) (for-all count? v)))

  (define (datum-record d)
    (and (pair? d) (list? d)
         (case (car d)
           [(undo-history)
            (and (fx= (length d) 5) (eqv? (cadr d) 1) (count? (caddr d)) (count? (cadddr d))
                 (fixnum? (list-ref d 4)))]
           [(group)
            (and (fx>= (length d) 6) (count? (cadr d)) (count? (caddr d)) (fixnum? (cadddr d))
                 (count-list? (list-ref d 4)) (edits! (list-tail d 5)))]
           [(more) (and (fx>= (length d) 3) (count? (cadr d)) (edits! (cddr d)))]
           [(at root prune) (and (fx= (length d) 2) (count? (cadr d)))]
           [(saved) (and (fx= (length d) 4) (count-list? (cdr d)))]
           [else #f])))

  ;; A crash can leave a record cut short, so reading stops at the first
  ;; datum that does not read or has no record's shape. Bytes that are not
  ;; UTF-8 read as replacement characters, which only a record cut short
  ;; holds: raising on them would lose the records read ahead of them.
  ;; Chez's reader raises a lexical violation that is also an i/o read
  ;; error, so the test is for the lexical one: a failing disk must raise.
  (define (read-log file)
    (if (not (file-exists? file))
        (values '() #f)
        (call-with-port
          (open-file-input-port file (file-options) (buffer-mode block)
            (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace)))
          (lambda (p)
            (let ([records '()])
              (guard (c [(or (lexical-violation? c) (assertion-violation? c)) (values (reverse records) #t)])
                (let loop ()
                  (let ([d (get-datum p)])
                    (cond
                      [(eof-object? d) (values (reverse records) #f)]
                      [(datum-record d) (set! records (cons d records)) (loop)]
                      [else (values (reverse records) #t)])))))))))

  (define (make-folders! folder)
    (unless (or (string=? folder "") (file-directory? folder))
      (make-folders! (path-parent folder))
      (guard (c [(file-directory? folder) (void)])
        (mkdir folder #o700))))

  (define (sync! port file)
    (flush-output-port port)
    (unless (fx= (c-fdatasync (port-file-descriptor port)) 0)
      (raise (condition (make-i/o-write-error) (make-who-condition 'undo-log)
                        (make-message-condition "cannot write the log to disk")
                        (make-irritants-condition (list file))))))

  ;; Some file systems cannot flush a folder; the file itself is flushed.
  (define (sync-folder! folder)
    (let ([fd (c-open folder 0)])
      (when (fx>= fd 0)
        (c-fsync fd)
        (c-close fd))))

  (define private
    (file-options no-fail perm-no-group-read perm-no-group-write perm-no-other-read perm-no-other-write))

  (define private-append
    (file-options no-fail no-truncate append
                  perm-no-group-read perm-no-group-write perm-no-other-read perm-no-other-write))

  (define (log-size file)
    (if (file-exists? file)
        (call-with-port (open-file-input-port file) port-length)
        0))

  (define (append-log! file bytes)
    (make-folders! (path-parent file))
    (let ([p (open-file-output-port file private-append)])
      (dynamic-wind
        void
        (lambda () (put-bytevector p bytes) (sync! p file))
        (lambda () (close-port p)))))

  ;; The new log replaces the old by a rename, so a crash leaves one or
  ;; the other whole.
  (define (replace-log! file bytes)
    (let ([folder (path-parent file)] [temporary (string-append file ".new")])
      (make-folders! folder)
      (let ([p (open-file-output-port temporary private)])
        (dynamic-wind
          void
          (lambda () (put-bytevector p bytes) (sync! p temporary))
          (lambda () (close-port p))))
      (rename-file temporary file)
      (sync-folder! folder)))

  (define (set-log-aside! file)
    (let ([aside (string-append file ".stale")])
      (when (file-exists? file)
        (rename-file file aside)
        (sync-folder! (path-parent file)))
      aside))

  (define (delete-log! file)
    (delete-file file #f))

  (define (delete-tree! path)
    (if (file-directory? path #f)
        (begin
          (for-each (lambda (name) (delete-tree! (string-append path "/" name))) (directory-list path))
          (delete-directory path))
        (delete-file path #f)))

  ;; A rename replaces only a file or an empty folder, so what the logs
  ;; hold under the new path is of files no longer there.
  (define (move-logs! from to)
    (for-each
      (lambda (from to)
        (when (file-exists? from #f)
          (when (file-exists? to #f) (delete-tree! to))
          (make-folders! (path-parent to))
          (rename-file from to)
          (sync-folder! (path-parent from))
          (sync-folder! (path-parent to))))
      (list (string-append from ".ss") from)
      (list (string-append to ".ss") to))))
