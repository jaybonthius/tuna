#!tuna
;; Imports no plugin, so a test that reloads file-watch can use it while
;; file-watch and its importers unload.

(define %readlink (begin (load-shared-object #f) (foreign-procedure "readlink" (string u8* size_t) ssize_t)))

(define %kcmp-file 0)
(define %syscall-kcmp 312)
(define %syscall (foreign-procedure (__varargs_after 1) "syscall" (long int int int unsigned-long unsigned-long) long))

(define (%link-target fd)
  (let* ([bytes (make-bytevector 256)] [n (%readlink (format "/proc/self/fd/~a" fd) bytes 256)])
    (and (> n 0) (utf8->string (bytevector-truncate! bytes n)))))

(define (%descriptors-to targets)
  (filter (lambda (fd) (member (%link-target fd) targets))
          (map string->number (directory-list "/proc/self/fd"))))

(define (%same-file? a b)
  (= 0 (%syscall %syscall-kcmp (get-process-id) (get-process-id) %kcmp-file a b)))

(define (%lines-starting text prefix)
  (let ([p (open-string-input-port text)])
    (let loop ([n 0])
      (let ([line (get-line p)])
        (cond
          [(eof-object? line) n]
          [(and (>= (string-length line) (string-length prefix))
                (string=? prefix (substring line 0 (string-length prefix))))
           (loop (+ n 1))]
          [else (loop n)])))))

;; Each inotify instance is open on two descriptors, the main thread's and
;; the job's copies, so they are grouped by the open file they share. A
;; job may close one while it is read, and a closed one has no watches.
(define (inotify-watch-counts)
  (let loop ([fds (%descriptors-to '("anon_inode:inotify"))] [counts '()])
    (if (null? fds)
        (list-sort < counts)
        (let ([info (guard (c [(i/o-error? c) #f])
                      (call-with-input-file (format "/proc/self/fdinfo/~a" (car fds)) get-string-all))])
          (loop (remp (lambda (fd) (%same-file? fd (car fds))) (cdr fds))
                (if info (cons (%lines-starting info "inotify wd:") counts) counts))))))

(define (watch-descriptors) (%descriptors-to '("anon_inode:inotify" "anon_inode:[eventfd]")))

;; Holds the main thread until n of the numbers in held are closed, so
;; nothing on it writes meanwhile, then opens files until each number freed
;; is one of theirs: a later write through a freed number lands in a file.
(define (take-freed! held n)
  (let ([deadline (+ (real-time) 30000)])
    (let wait ()
      (unless (>= (length (remp (lambda (fd) (memv fd (watch-descriptors))) held)) n)
        (when (> (real-time) deadline) (error 'take-freed! "the job did not close its descriptors"))
        (wait))))
  (let ([freed (remp (lambda (fd) (memv fd (watch-descriptors))) held)])
    (let loop ([i 0] [taken '()])
      (if (for-all (lambda (fd) (exists (lambda (t) (= fd (port-file-descriptor (car t)))) taken)) freed)
          taken
          (let ([path (format "~a/freed-~a" (getenv "HOME") i)])
            (when (= i 20) (error 'take-freed! "no file took a freed number" freed))
            (loop (+ i 1) (cons (cons (open-file-output-port path (file-options no-fail)) path) taken)))))))

(define (written taken)
  (for-each (lambda (t) (close-port (car t))) taken)
  (map cdr (filter (lambda (t) (> (call-with-port (open-file-input-port (cdr t)) port-length) 0)) taken)))
