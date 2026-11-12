(library (files disk)
  (export true-path read-file revert-file save-file fnv-basis
          failure failure? failure-violation? failure-message failure-irritants
          contents-document contents-length contents-hash contents-bom? contents-crlf?)
  (import (chezscheme) (document))

  ;; Each call that can wait on a slow or network file system lets other
  ;; threads collect meanwhile, so it takes no Scheme string: memory it
  ;; gets is foreign.
  (define c-realpath
    (begin
      (load-shared-object #f)
      (foreign-procedure __collect_safe "realpath" (uptr uptr) uptr)))
  (define c-stat (foreign-procedure __collect_safe "stat" (uptr uptr) int))
  (define c-open (foreign-procedure __collect_safe "open" (uptr int) int))
  (define c-fsync (foreign-procedure __collect_safe "fsync" (int) int))
  (define c-close (foreign-procedure "close" (int) int))
  (define c-free (foreign-procedure "free" (uptr) void))
  (define c-geteuid (foreign-procedure "geteuid" () unsigned-32))

  (define (call-with-c-string s proc)
    (let* ([bv (string->utf8 s)]
           [n (bytevector-length bv)]
           [p (foreign-alloc (fx+ n 1))])
      (dynamic-wind
        void
        (lambda ()
          (do ([i 0 (fx+ i 1)]) ((fx= i n))
            (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
          (foreign-set! 'unsigned-8 p n 0)
          (proc p))
        (lambda () (foreign-free p)))))

  (define (c-string->string p)
    (let ([n (let loop ([i 0]) (if (fx= (foreign-ref 'unsigned-8 p i) 0) i (loop (fx+ i 1))))])
      (let ([bv (make-bytevector n)])
        (do ([i 0 (fx+ i 1)]) ((fx= i n))
          (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 p i)))
        (utf8->string bv))))

  (define (realpath path)
    (call-with-c-string path
      (lambda (p)
        (let ([r (c-realpath p 0)])
          (and (not (eqv? r 0))
               (let ([s (c-string->string r)])
                 (c-free r)
                 s))))))

  ;; The offsets of st_nlink and st_uid in x86-64 Linux's struct stat,
  ;; the only layout Tuna is built for.
  (define stat-size 144)
  (define nlink-offset 16)
  (define uid-offset 28)

  (define (link-count-and-owner path)
    (let ([buffer (foreign-alloc stat-size)])
      (dynamic-wind
        void
        (lambda ()
          (and (fx= (call-with-c-string path (lambda (p) (c-stat p buffer))) 0)
               (cons (foreign-ref 'unsigned-64 buffer nlink-offset)
                     (foreign-ref 'unsigned-32 buffer uid-offset))))
        (lambda () (foreign-free buffer)))))

  (define (join folder name)
    (if (and (fx> (string-length folder) 0)
             (char=? (string-ref folder (fx- (string-length folder) 1)) #\/))
        (string-append folder name)
        (string-append folder "/" name)))

  (define (absolute path)
    (cond
      [(and (fx>= (string-length path) 1) (char=? (string-ref path 0) #\/)) path]
      [(or (string=? path "~") (and (fx>= (string-length path) 2) (string=? (substring path 0 2) "~/")))
       (string-append (or (getenv "HOME") "") (substring path 1 (string-length path)))]
      [else (join (current-directory) path)]))

  ;; A missing file's path still resolves the folders that exist, so the
  ;; first save writes where a later visit will look.
  (define (true-path path)
    (let resolve ([path (absolute path)])
      (or (realpath path)
          (let ([folder (path-parent path)] [name (path-last path)])
            (if (or (string=? folder path) (string=? folder ""))
                path
                (let ([folder (resolve folder)])
                  (cond
                    [(or (string=? name "") (string=? name ".")) folder]
                    [(string=? name "..") (path-parent folder)]
                    [else (join folder name)])))))))

  (define fnv-basis 2166136261)

  (define (fnv bv start end h)
    (let loop ([i start] [h h])
      (if (fx= i end)
          h
          (loop (fx+ i 1) (fxand (fx* (fxxor h (bytevector-u8-ref bv i)) 16777619) #xFFFFFFFF)))))

  ;; Irritants cross to the main thread as text, since a job sends only
  ;; plain data. A violation stays one, so a defect here does not pass for
  ;; a disk error.
  (define (failure c)
    (define (plain x) (if (or (string? x) (symbol? x) (number? x)) x (format "~s" x)))
    (cond
      [(not (condition? c)) (list 'failed #f (format "non-condition value ~s" c) '())]
      [else
       (let ([violation (violation? c)]
             [message (if (message-condition? c) (condition-message c) "failed")]
             [irritants (if (irritants-condition? c) (condition-irritants c) '())])
         (cond
           [(and (format-condition? c) (guard (e [#t #f]) (apply format message irritants)))
            => (lambda (text) (list 'failed violation text '()))]
           [else (list 'failed violation message (if (list? irritants) (map plain irritants) '()))]))]))

  (define (failure? v) (and (pair? v) (eq? (car v) 'failed)))
  (define (failure-violation? f) (cadr f))
  (define (failure-message f) (caddr f))
  (define (failure-irritants f) (cadddr f))

  (define (read-bytes path)
    (let ([bytes (call-with-port (open-file-input-port path) get-bytevector-all)])
      (if (eof-object? bytes) (make-bytevector 0) bytes)))

  (define (check-not-folder path)
    (when (file-directory? path)
      (raise (condition (make-i/o-filename-error path) (make-message-condition "is a folder")
                        (make-irritants-condition (list path))))))

  (define (bom? bytes)
    (and (fx>= (bytevector-length bytes) 3)
         (fx= (bytevector-u8-ref bytes 0) #xEF)
         (fx= (bytevector-u8-ref bytes 1) #xBB)
         (fx= (bytevector-u8-ref bytes 2) #xBF)))

  (define (crlf? bytes start)
    (let ([n (bytevector-length bytes)])
      (let loop ([i start] [seen #f])
        (cond
          [(fx= i n) seen]
          [(fx= (bytevector-u8-ref bytes i) 10)
           (and (fx> i start) (fx= (bytevector-u8-ref bytes (fx- i 1)) 13) (loop (fx+ i 1) #t))]
          [else (loop (fx+ i 1) seen)]))))

  (define (text-bytes bytes start crlf)
    (let ([n (bytevector-length bytes)])
      (cond
        [crlf
         (let* ([lines (let loop ([i start] [k 0])
                         (cond
                           [(fx= i n) k]
                           [(fx= (bytevector-u8-ref bytes i) 10) (loop (fx+ i 1) (fx+ k 1))]
                           [else (loop (fx+ i 1) k)]))]
                [out (make-bytevector (fx- (fx- n start) lines))])
           (let loop ([i start] [j 0])
             (unless (fx= i n)
               (let ([b (bytevector-u8-ref bytes i)])
                 (if (and (fx= b 13) (fx< (fx+ i 1) n) (fx= (bytevector-u8-ref bytes (fx+ i 1)) 10))
                     (loop (fx+ i 1) j)
                     (begin (bytevector-u8-set! out j b) (loop (fx+ i 1) (fx+ j 1)))))))
           out)]
        [(fx= start 0) bytes]
        [else
         (let ([out (make-bytevector (fx- n start))])
           (bytevector-copy! bytes start out 0 (fx- n start))
           out)])))

  (define (text-document bytes)
    (document:replace (document:from-datum '(buffers:text ())) 1 1 (document:from-utf8 bytes)))

  ;; A file's contents as read, a vector since a job sends plain data only.
  (define (make-contents doc length hash bom crlf) (vector doc length hash bom crlf))
  (define (contents-document c) (vector-ref c 0))
  (define (contents-length c) (vector-ref c 1))
  (define (contents-hash c) (vector-ref c 2))
  (define (contents-bom? c) (vector-ref c 3))
  (define (contents-crlf? c) (vector-ref c 4))

  (define (decode bytes)
    (let* ([bom (bom? bytes)]
           [start (if bom 3 0)]
           [crlf (crlf? bytes start)])
      (make-contents (text-document (text-bytes bytes start crlf))
                     (bytevector-length bytes)
                     (fnv bytes 0 (bytevector-length bytes) fnv-basis)
                     bom
                     crlf)))

  (define (read-file path)
    (check-not-folder path)
    (if (file-exists? path)
        (decode (read-bytes path))
        (make-contents (text-document (make-bytevector 0)) 0 fnv-basis #f #f)))

  (define (char-token doc i)
    (let loop ([p (document:position doc i (document:unit characters))])
      (let ([t (document:token doc p)])
        (if (or (char? t) (document:atom? t))
            (values t p)
            (loop (fx+ p 1))))))

  ;; Atoms read as U+FFFC, so two of them, or an atom and the character,
  ;; are the same only if their tokens are.
  (define (same-object? old i new j)
    (let-values ([(a pa) (char-token old i)] [(b pb) (char-token new j)])
      (or (and (char? a) (char? b))
          (and (document:node? a) (document:node? b)
               (equal? (document:datums (document:slice old pa (fx+ pa 1)))
                       (document:datums (document:slice new pb (fx+ pb 1))))))))

  (define (changed-range old new)
    (let* ([a (document:text old)]
           [b (document:text new)]
           [na (string-length a)]
           [nb (string-length b)]
           [m (fxmin na nb)])
      (define (same? i j)
        (let ([c (string-ref a i)])
          (and (char=? c (string-ref b j))
               (or (not (char=? c #\xFFFC)) (same-object? old i new j)))))
      (define (position doc k)
        (fxmax 1 (document:position doc k (document:unit characters))))
      (let* ([prefix (let loop ([i 0]) (if (and (fx< i m) (same? i i)) (loop (fx+ i 1)) i))]
             [suffix (let loop ([k 0])
                       (if (and (fx< k (fx- m prefix)) (same? (fx- na (fx+ k 1)) (fx- nb (fx+ k 1))))
                           (loop (fx+ k 1))
                           k))])
        (list (position old prefix) (position old (fx- na suffix))
              (position new prefix) (position new (fx- nb suffix))))))

  (define (revert-file path old)
    (check-not-folder path)
    (unless (file-exists? path)
      (raise (condition (make-i/o-file-does-not-exist-error path) (make-message-condition "no such file")
                        (make-irritants-condition (list path)))))
    (let ([contents (decode (read-bytes path))])
      (cons contents (changed-range old (contents-document contents)))))

  (define (encode doc bom crlf)
    (let-values ([(out extract) (open-bytevector-output-port)])
      (when bom (put-bytevector out #vu8(#xEF #xBB #xBF)))
      (document:for-each-utf8-chunk doc 0 (document:length doc)
        (lambda (bv start end)
          (if crlf
              (let loop ([i start] [from start])
                (cond
                  [(fx= i end) (put-bytevector out bv from (fx- end from))]
                  [(fx= (bytevector-u8-ref bv i) 10)
                   (put-bytevector out bv from (fx- i from))
                   (put-bytevector out #vu8(13 10))
                   (loop (fx+ i 1) (fx+ i 1))]
                  [else (loop (fx+ i 1) from)]))
              (put-bytevector out bv start (fx- end start)))))
      (extract)))

  (define (changed-on-disk? path length hash)
    (and (file-exists? path)
         (let ([bytes (read-bytes path)])
           (not (and (= (bytevector-length bytes) length)
                     (= (fnv bytes 0 (bytevector-length bytes) fnv-basis) hash))))))

  (define (flush! port path)
    (flush-output-port port)
    (unless (fx= (c-fsync (port-file-descriptor port)) 0)
      (raise (condition (make-i/o-write-error) (make-message-condition "cannot write to disk")
                        (make-irritants-condition (list path))))))

  (define (write-bytes! port path bytes)
    (dynamic-wind
      void
      (lambda () (put-bytevector port bytes) (flush! port path))
      (lambda () (close-port port))))

  (define (write-in-place! path bytes)
    (write-bytes! (open-file-output-port path (file-options no-fail)) path bytes))

  ;; Some file systems cannot flush a folder; the file itself is flushed.
  (define (flush-folder! folder)
    (let ([fd (call-with-c-string folder (lambda (p) (c-open p 0)))])
      (when (fx>= fd 0)
        (c-fsync fd)
        (c-close fd))))

  ;; The temporary name carries the process and thread, since two Tunas,
  ;; or two jobs, may save one file at once.
  (define (write-by-rename! path bytes)
    (let* ([folder (path-parent path)]
           [temporary (join folder (format ".~a.tuna-~a-~a" (path-last path) (get-process-id) (get-thread-id)))]
           [port (guard (c [(i/o-file-protection-error? c) #f])
                   (open-file-output-port temporary (file-options no-fail)))])
      (and port
           (begin
             ;; The mode is set before any byte is written, so a private
             ;; file's text is never readable under the default mode.
             (guard (c [#t (close-port port) (delete-file temporary #f) (raise c)])
               (when (file-exists? path) (chmod temporary (get-mode path)))
               (write-bytes! port temporary bytes)
               (rename-file temporary path))
             (flush-folder! folder)
             #t))))

  ;; Renaming over a file with other hard links would split them, and the
  ;; new file would belong to the user rather than the file's owner.
  (define (in-place? path)
    (let ([stat (link-count-and-owner path)])
      (and stat (or (> (car stat) 1) (not (= (cdr stat) (c-geteuid)))))))

  (define (save-file path doc bom crlf length hash check?)
    (let ([folder (path-parent path)])
      (unless (file-directory? folder)
        (raise (condition (make-i/o-file-does-not-exist-error folder) (make-message-condition "no such folder")
                          (make-irritants-condition (list folder)))))
      (check-not-folder path)
      (if (and check? (changed-on-disk? path length hash))
          'changed
          (let ([bytes (encode doc bom crlf)])
            (unless (and (not (and (file-exists? path) (in-place? path)))
                         (write-by-rename! path bytes))
              (write-in-place! path bytes))
            (list (bytevector-length bytes) (fnv bytes 0 (bytevector-length bytes) fnv-basis)))))))
