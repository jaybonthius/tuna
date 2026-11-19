(library (files disk)
  (export true-path true-folders-path writable? make-folders read-file revert-file save-file fnv-basis
          failure failure? failure-violation? failure-message failure-irritants failure-filename
          failure-already-exists?
          rename-path copy-path delete-path trash-path make-new-folder
          contents-document contents-length contents-hash contents-bom? contents-crlf?)
  (import (chezscheme) (document) (files attributes) (files system))

  ;; Each call that can wait on a slow or network file system lets other
  ;; threads collect meanwhile, so it takes no Scheme string: memory it
  ;; gets is foreign.
  (define c-access
    (begin
      (load-shared-object #f)
      (foreign-procedure __collect_safe "access" (uptr int) int)))
  (define c-open (foreign-procedure __collect_safe "open" (uptr int) int))
  (define c-fsync (foreign-procedure __collect_safe "fsync" (int) int))
  (define c-close (foreign-procedure "close" (int) int))
  (define c-geteuid (foreign-procedure "geteuid" () unsigned-32))
  (define c-rename (foreign-procedure __collect_safe __errno "rename" (uptr uptr) int))
  (define c-symlink (foreign-procedure __collect_safe __errno "symlink" (uptr uptr) int))
  (define c-utimensat (foreign-procedure __collect_safe "utimensat" (int uptr uptr int) int))

  (define (join folder name)
    (if (and (fx> (string-length folder) 0)
             (char=? (string-ref folder (fx- (string-length folder) 1)) #\/))
        (string-append folder name)
        (string-append folder "/" name)))

  ;; A symbolic link is renamed, copied or deleted itself, so only the
  ;; folders above it are resolved.
  (define (true-folders-path path)
    (let ([name (path-last path)])
      (if (member name '("" "." ".."))
          (true-path path)
          (join (true-path (let ([folder (path-parent path)]) (if (string=? folder "") "." folder))) name))))

  (define write-access 2)

  (define (writable? path)
    (fx= (call-with-c-string path (lambda (p) (c-access p write-access))) 0))

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
      [(not (condition? c)) (list 'failed #f (format "non-condition value ~s" c) '() #f #f)]
      [else
       (let ([violation (violation? c)]
             [message (if (message-condition? c) (condition-message c) "failed")]
             [irritants (if (irritants-condition? c) (condition-irritants c) '())]
             [filename (and (i/o-filename-error? c) (plain (i/o-error-filename c)))]
             [already-exists (i/o-file-already-exists-error? c)])
         (cond
           [(and (format-condition? c) (guard (e [#t #f]) (apply format message irritants)))
            => (lambda (text) (list 'failed violation text '() filename already-exists))]
           [else (list 'failed violation message (if (list? irritants) (map plain irritants) '()) filename
                       already-exists)]))]))

  (define (failure? v) (and (pair? v) (eq? (car v) 'failed)))
  (define (failure-violation? f) (cadr f))
  (define (failure-message f) (caddr f))
  (define (failure-irritants f) (cadddr f))
  (define (failure-filename f) (list-ref f 4))
  (define (failure-already-exists? f) (list-ref f 5))

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
    (let ([attributes (guard (c [(i/o-error? c) #f]) (read-file-attributes (true-path path)))])
      (and attributes
           (or (> (file-attributes-links attributes) 1)
               (not (= (file-attributes-uid attributes) (c-geteuid)))))))

  (define (make-folders folder)
    (unless (file-exists? folder)
      (make-folders (path-parent folder))
      (mkdir folder))
    #t)

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
            (list (bytevector-length bytes) (fnv bytes 0 (bytevector-length bytes) fnv-basis))))))

  (define (inside? path folder)
    (let ([n (string-length folder)])
      (or (string=? path folder)
          (and (fx> (string-length path) n) (string=? (substring path 0 n) folder)
               (char=? (string-ref path n) #\/)))))

  (define (check-not-inside who from to)
    (cond
      [(string=? to from)
       (raise (condition (make-i/o-filename-error to) (make-who-condition who)
                         (make-message-condition "the same file") (make-irritants-condition (list from))))]
      [(inside? to from)
       (raise (condition (make-i/o-filename-error to) (make-who-condition who)
                         (make-message-condition "cannot put a folder inside itself")
                         (make-irritants-condition (list from to))))]))

  (define (check-absent who path replace?)
    (when (and (not replace?) (file-exists? path #f))
      (raise (condition (make-i/o-file-already-exists-error path) (make-who-condition who)
                        (make-message-condition "file exists") (make-irritants-condition (list path))))))

  (define enotdir 20)
  (define eisdir 21)
  (define exdev 18)
  (define enotempty 39)

  ;; Copying onto a folder would merge into it, so the target goes first,
  ;; and only when rename(2) would replace it: a file by a file, an empty
  ;; folder by a folder. A rename then gives one result on any file system.
  (define (clear-target! from to)
    (when (file-exists? to #f)
      (let ([folder? (file-directory? from #f)] [target-folder? (file-directory? to #f)])
        (cond
          [(and folder? (not target-folder?)) (raise-system-failure 'rename-path from enotdir)]
          [(and target-folder? (not folder?)) (raise-system-failure 'rename-path from eisdir)]
          [(and target-folder? (pair? (directory-list to))) (raise-system-failure 'rename-path from enotempty)])
        (delete-path to))))

  ;; Across file systems rename(2) fails, and the file is copied, then
  ;; deleted, as mv does.
  (define (rename-path from to replace?)
    (check-not-inside 'rename-path from to)
    (check-absent 'rename-path to replace?)
    (let-values ([(result errno)
                  (call-with-c-string from
                    (lambda (f) (call-with-c-string to (lambda (t) (c-rename f t)))))])
      (cond
        [(fx= result 0) #t]
        [(fx= errno exdev)
         (clear-target! from to)
         (copy-path from to #f)
         (delete-path from)]
        [else (raise-system-failure 'rename-path from errno)])))

  (define at-fdcwd -100)
  (define at-symlink-nofollow #x100)
  (define utime-omit (fx- (fxsll 1 30) 2))

  (define (set-modified! path seconds)
    (let ([times (foreign-alloc 32)])
      (dynamic-wind
        void
        (lambda ()
          (foreign-set! 'integer-64 times 0 0)
          (foreign-set! 'integer-64 times 8 utime-omit)
          (foreign-set! 'integer-64 times 16 seconds)
          (foreign-set! 'integer-64 times 24 0)
          (call-with-c-string path (lambda (p) (c-utimensat at-fdcwd p times at-symlink-nofollow))))
        (lambda () (foreign-free times)))))

  (define copy-chunk 65536)

  (define (copy-bytes! from to replace?)
    (call-with-port (open-file-input-port from)
      (lambda (in)
        (call-with-port (open-file-output-port to (if replace? (file-options no-fail) (file-options)))
          (lambda (out)
            (let ([chunk (make-bytevector copy-chunk)])
              (let loop ()
                (let ([n (get-bytevector-n! in chunk 0 copy-chunk)])
                  (unless (eof-object? n)
                    (put-bytevector out chunk 0 n)
                    (loop))))))))))

  (define (copy-path from to replace?)
    (check-not-inside 'copy-path from to)
    (let copy ([from from] [to to])
      (let ([attributes (read-file-attributes from)])
        (let ([type (file-attributes-type attributes)])
          (cond
            [(eq? type (file-type folder))
             (if (file-exists? to #f)
                 (unless (and replace? (file-directory? to #f))
                   (check-absent 'copy-path to #f))
                 (mkdir to))
             (for-each (lambda (name) (copy (join from name) (join to name)))
                       (list-sort string<? (directory-list from)))
             (chmod to (file-attributes-mode attributes))]
            [(eq? type (file-type link))
             (check-absent 'copy-path to replace?)
             (when (file-exists? to #f)
               (if (file-directory? to #f)
                   (raise-system-failure 'copy-path to eisdir)
                   (delete-file to #t)))
             (let-values ([(result errno)
                           (call-with-c-string (file-attributes-target attributes)
                             (lambda (target) (call-with-c-string to (lambda (p) (c-symlink target p)))))])
               (unless (fx= result 0)
                 (raise-system-failure 'copy-path to errno)))]
            [(eq? type (file-type other))
             (raise (condition (make-i/o-filename-error from) (make-who-condition 'copy-path)
                               (make-message-condition "cannot copy a special file")
                               (make-irritants-condition (list from))))]
            [else
             (copy-bytes! from to replace?)
             (chmod to (file-attributes-mode attributes))])
          (set-modified! to (file-attributes-modified attributes)))))
    #t)

  (define (delete-path path)
    (let delete ([path path])
      (if (file-directory? path #f)
          (begin
            (for-each (lambda (name) (delete (join path name))) (directory-list path))
            (delete-directory path #t))
          (delete-file path #t)))
    #t)

  (define (two-digits n) (if (< n 10) (format "0~a" n) (number->string n)))

  (define (trash-date)
    (let ([d (current-date)])
      (format "~a-~a-~aT~a:~a:~a" (date-year d) (two-digits (date-month d)) (two-digits (date-day d))
              (two-digits (date-hour d)) (two-digits (date-minute d)) (two-digits (date-second d)))))

  (define (percent-encoded path)
    (let-values ([(out extract) (open-string-output-port)])
      (bytevector-for-each
        (lambda (b)
          (let ([c (integer->char b)])
            (if (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (memv c '(#\/ #\- #\_ #\. #\~)))
                (put-char out c)
                (put-string out (string-append "%" (string-upcase (if (< b 16) (format "0~x" b) (format "~x" b))))))))
        (string->utf8 path))
      (extract)))

  (define (bytevector-for-each proc bv)
    (do ([i 0 (fx+ i 1)]) ((fx= i (bytevector-length bv)))
      (proc (bytevector-u8-ref bv i))))

  (define (trash-folder)
    (let ([data (let ([xdg (getenv "XDG_DATA_HOME")])
                  (if (and xdg (fx> (string-length xdg) 0)) xdg (join (or (getenv "HOME") "/") ".local/share")))])
      (join data "Trash")))

  ;; The info file is made first and exclusively, so two trashings of
  ;; files with one name never take the same name, as the freedesktop.org
  ;; trash specification asks.
  (define (trash-path path)
    (let* ([trash (trash-folder)] [files (join trash "files")] [info (join trash "info")])
      (for-each (lambda (folder)
                  (unless (file-exists? folder)
                    (make-folders folder)
                    (chmod folder #o700)))
                (list trash files info))
      (let loop ([n 1])
        (let* ([name (if (fx= n 1) (path-last path) (format "~a.~a" (path-last path) n))]
               [info-file (join info (string-append name ".trashinfo"))]
               [port (and (not (file-exists? (join files name) #f))
                          (guard (c [(i/o-file-already-exists-error? c) #f])
                            (open-file-output-port info-file (file-options) (buffer-mode block) (native-transcoder))))])
          (if port
              (begin
                (call-with-port port
                  (lambda (port)
                    (put-string port (format "[Trash Info]\nPath=~a\nDeletionDate=~a\n" (percent-encoded path) (trash-date)))))
                (guard (c [#t (delete-file info-file #f) (raise c)])
                  (rename-path path (join files name) #f))
                #t)
              (loop (fx+ n 1)))))))

  (define (make-new-folder path)
    (check-absent 'make-new-folder path #f)
    (make-folders path)))
