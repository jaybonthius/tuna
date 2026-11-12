(import (chezscheme) (tuna-test) (tuna core changes) (tuna core definitions)
        (except (tuna core main-thread) exit) (tuna plugin-manager) (tuna storage) (tuna saved))

(define root
  (let ([dir (format "/tmp/tuna-saved-test-~a" (get-process-id))])
    (mkdir dir)
    dir))

(define (path . parts) (apply string-append root (map (lambda (part) (string-append "/" part)) parts)))

(define (write-file! file text)
  (let loop ([dir (path-parent file)])
    (unless (file-directory? dir)
      (loop (path-parent dir))
      (mkdir dir)))
  (call-with-output-file file (lambda (p) (put-string p text)) 'replace))

(define (read-file file)
  (call-with-input-file file read))

(start-plugins! (string-append (current-directory) "/build/bin/tuna") root (path "config" "init.ss") (path "config" "lib") (path "library") (path "plugins"))
(start-storage! (path "saved") module-plugin-source)

(define (yield)
  (suspend (lambda (resume) (post! (lambda () (resume void))))))

(define (stored s)
  (let ([file (saved-file '(repl) (saved-name s))])
    (and (file-exists? file) (read-file file))))

;; Every datum here is defined at the top level, owned by the REPL, so the
;; test reads its file back by its name.
(define names (make-eq-hashtable))
(define (saved-name s) (hashtable-ref names s #f))

(define-syntax define-test-saved
  (syntax-rules ()
    [(_ id initial check)
     (begin
       (define-saved id initial check)
       (hashtable-set! names id 'id))]))

(write-file! (saved-file '(repl) 'loaded) "(\"text\" #vu8(1 2) #(\"inner\"))\n")
(define-test-saved loaded '() list?)
(define-test-saved changed '() list?)
(define-test-saved printing '() list?)
(define-test-saved flag #t boolean?)
(define-test-saved shared '() list?)
(define-test-saved raced '() list?)
(define-test-saved big '() list?)
(define-test-saved blocked 0 fixnum?)
(define-test-saved deep '() list?)
(define-test-saved each-0 0 fixnum?)
(define-test-saved each-1 0 fixnum?)
(define-test-saved each-2 0 fixnum?)
(define-test-saved each-3 0 fixnum?)
(define-test-saved each-4 0 fixnum?)
(define-test-saved each-5 0 fixnum?)
(define-test-saved each-6 0 fixnum?)
(define-test-saved each-7 0 fixnum?)
(define each (list each-0 each-1 each-2 each-3 each-4 each-5 each-6 each-7))

(define (encoded folder)
  (call-with-string-output-port
    (lambda (p)
      (string-for-each (lambda (c) (if (char=? c #\/) (put-string p "%2F") (put-char p c))) folder))))

;; The main thread keeps running posted work while the threads run, so
;; their sets race with the writes it starts.
(define (run-threads thunks)
  (let ([m (make-mutex)] [finished 0])
    (let ([threads (map (lambda (thunk)
                          (fork-thread
                            (lambda ()
                              (thunk)
                              (with-mutex m (set! finished (+ finished 1))))))
                        thunks)])
      (let loop ()
        (unless (= (with-mutex m finished) (length thunks))
          (yield)
          (loop)))
      (for-each thread-join threads))))

(define (tests)
  (test "a file's name comes from the source of its module's plugin, then the module and name"
    (write-file! (path "plugins" "fetched.installed") "((git \"https://example.org/bob/fetched\"))\n")
    (write-file! (path "plugins" "fetched" "fetched.sls") "#!tuna\n")
    (write-file! (path "home-made" "made.sls") "#!tuna\n")
    (write-file! (path "plugins" "made.installed") (format "((local ~s))\n" (path "home-made")))
    (write-file! (path "plugins" "placed" "placed.sls") "#!tuna\n")
    (write-file! (path "config" "lib" "mine" "util.sls") "#!tuna\n")
    (check-equal? (path "saved" "https:%2F%2Fexample.org%2Fbob%2Ffetched" "fetched" "hits.ss")
      (saved-file '(fetched) 'hits))
    (check-equal? (path "saved" (encoded (path "home-made")) "made" "hits.ss") (saved-file '(made) 'hits))
    (check-equal? (path "saved" (encoded (path "plugins" "placed")) "placed" "hits.ss") (saved-file '(placed) 'hits))
    (check-equal? (path "saved" "user" "mine" "util" "hits.ss") (saved-file '(mine util) 'hits))
    (check-equal? (path "saved" "tuna" "files" "hits.ss") (saved-file '(files) 'hits))
    (check-equal? (path "saved" "tuna" "fetched" "other" "hits.ss") (saved-file '(fetched other) 'hits))
    (check-equal? (path "saved" "user" "init" "a%2Fb%25c.ss") (saved-file '(init) (string->symbol "a/b%c")))
    (check-equal? (path "saved" "user" "repl" "%2E..ss") (saved-file '(repl) (string->symbol ".."))))

  ;; The plugin manager is a tool the configuration imports; what every
  ;; module imports must not depend on it. library-requirements needs a
  ;; library's information loaded, and lists only direct requirements.
  (test "the standard library needs no plugin manager"
    (check (not (member '(tuna plugin-manager)
                  (let loop ([todo '((tuna))] [seen '()])
                    (cond
                      [(null? todo) seen]
                      [(member (car todo) seen) (loop (cdr todo) seen)]
                      [else
                       (environment (car todo))
                       (invoke-library (car todo))
                       (loop (append (library-requirements (car todo)) (cdr todo))
                             (cons (car todo) seen))]))))))

  (test "sets from many threads: each file holds its datum's last value"
    (run-threads
      (map (lambda (s i)
             (lambda ()
               (do ([n 0 (+ n 1)]) ((= n 300))
                 (set-saved! s n)
                 (set-saved! shared (list i n)))))
           each (iota 8)))
    (finish-saved-data!)
    (check-equal? (make-list 8 299) (map stored each))
    (check-equal? (shared) (stored shared))
    (check-equal? 299 (cadr (shared))))

  (test "the file holds the value as it was when set, though it changes in place after"
    (let ([v (list (string-copy "before") (vector 1))])
      (set-saved! changed v)
      (string-set! (car v) 0 #\X)
      (vector-set! (cadr v) 0 2)
      (set-cdr! (cdr v) (list 'more))
      (finish-saved-data!)
      (check-equal? '("before" #(1)) (stored changed))))

  (test "a stored value is read with immutable strings and bytevectors"
    (check-equal? '("text" #vu8(1 2) #("inner")) (loaded))
    (check (immutable-string? (car (loaded))))
    (check (immutable-bytevector? (cadr (loaded))))
    (check (immutable-string? (vector-ref (caddr (loaded)) 0))))

  (test "#f is written as a value"
    (set-saved! flag #f)
    (finish-saved-data!)
    (check (file-exists? (saved-file '(repl) 'flag)))
    (check-equal? #f (read-file (saved-file '(repl) 'flag))))

  (test "set-saved! refuses a cycle"
    (let ([v (list 1 2)])
      (set-cdr! (cdr v) v)
      (check-raises (lambda (c) (and (assertion-violation? c) (eq? (condition-who c) 'set-saved!)))
        (set-saved! changed v))))

  ;; The other thread changes the first value in place while the writer
  ;; may still be printing it, then sets a second.
  (test "a set on another thread while the writer prints an earlier value"
    (let* ([file (saved-file '(repl) 'printing)]
           [first (map (lambda (i) (make-string 200 #\a)) (iota 5000))]
           [stop? #f]
           [partial 0]
           [reader (fork-thread
                     (lambda ()
                       (let loop ()
                         (unless stop?
                           (when (file-exists? file)
                             (let ([v (guard (c [#t #f]) (read-file file))])
                               (unless (or (equal? v '("second"))
                                           (and (list? v) (= (length v) 5000)
                                                (for-all (lambda (s) (equal? s (make-string 200 #\a))) v)))
                                 (set! partial (+ partial 1)))))
                           (loop)))))])
      (set-saved! printing first)
      (yield)
      (run-threads
        (list (lambda ()
                (do ([n 0 (+ n 1)]) ((= n 20))
                  (for-each (lambda (s) (string-fill! s (if (even? n) #\b #\c))) first))
                (set-car! first "changed")
                (set-saved! printing '("second")))))
      (finish-saved-data!)
      (set! stop? #t)
      (thread-join reader)
      (check-equal? 0 partial)
      (check-equal? '("second") (stored printing))))

  (test "a removal racing with sets never leaves the removed value's file behind"
    (do ([round 0 (+ round 1)]) ((= round 20))
      (run-threads
        (map (lambda (i)
               (lambda ()
                 (do ([n 0 (+ n 1)]) ((= n 200))
                   (if (= (random 3) 0)
                       (remove-saved! raced)
                       (set-saved! raced (list i n))))))
             (iota 4)))
      (when (odd? round) (remove-saved! raced))
      (finish-saved-data!)
      (if (null? (raced))
          (check (not (stored raced)))
          (check-equal? (raced) (stored raced)))))

  (test "a reader never sees part of a file"
    (let* ([stop? #f]
           [partial 0]
           [reads 0]
           [file (saved-file '(repl) 'big)]
           [reader (fork-thread
                     (lambda ()
                       (let loop ()
                         (unless stop?
                           (when (file-exists? file)
                             (let ([v (guard (c [#t #f]) (read-file file))])
                               (set! reads (+ reads 1))
                               (unless (and (list? v) (= (length v) 5000) (for-all (lambda (s) (equal? s (car v))) v))
                                 (set! partial (+ partial 1)))))
                           (loop)))))])
      (do ([n 0 (+ n 1)]) ((= n 40))
        (set-saved! big (make-list 5000 (format "version ~a" n)))
        (yield))
      (finish-saved-data!)
      (set! stop? #t)
      (thread-join reader)
      (check (> reads 0))
      (check-equal? 0 partial)
      (check-equal? (big) (stored big))
      (check-equal? '() (filter (lambda (f) (equal? (path-extension f) "new")) (directory-list (path-parent file))))))

  ;; Printed in full, this value would take 2^40 conses.
  (test "shared structure is written once and read back shared"
    (let ([v (let loop ([i 0] [x '()]) (if (= i 40) x (loop (+ i 1) (cons x x))))]
          [file (saved-file '(repl) 'deep)])
      (set-saved! deep v)
      (finish-saved-data!)
      (check (< (bytevector-length (call-with-port (open-file-input-port file) get-bytevector-all)) 1000))
      (let ([read-back (read-file file)])
        (check (eq? (car read-back) (cdr read-back))))))

  ;; A FIFO at the temporary file's name makes the writer wait in open, as
  ;; it would for a slow disk; fsync then fails on it, since a FIFO cannot
  ;; be synchronized.
  (test "the main thread goes on while the writer waits for the disk, and a failed write is reported"
    (let* ([file (saved-file '(repl) 'blocked)]
           [temporary (format "~a.~a.new" file (get-process-id))]
           [reported '()])
      (define (capture report c) (set! reported (cons (get-thread-id) reported)))
      (write-file! file "0\n")
      (check-equal? 0 (system (format "mkfifo '~a'" temporary)))
      (advice-add! report capture)
      (set-saved! blocked 1)
      (yield)
      (collect-rendezvous)
      (let ([went-on (spawn-task (lambda () 'went-on))])
        (check-equal? 'went-on (join-task went-on)))
      (check-equal? 0 (read-file file))
      (let ([drain (fork-thread (lambda () (call-with-port (open-file-input-port temporary) get-bytevector-all)))])
        (let loop () (when (null? reported) (yield) (loop)))
        (thread-join drain))
      (advice-remove! report capture)
      (check-equal? (list (get-thread-id)) reported)
      (check (not (file-exists? temporary)))
      (check-equal? 0 (read-file file))
      (set-saved! blocked 2)
      (finish-saved-data!)
      (check-equal? 2 (read-file file)))))

(post! (lambda ()
         (tests)
         (system (format "rm -rf '~a'" root))
         (test-exit)))
(run-main-loop)
