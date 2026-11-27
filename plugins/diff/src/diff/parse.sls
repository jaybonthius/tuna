(library (diff parse)
  (export parse-diff
          file? file-old-path file-new-path file-path file-old-path-bytes file-new-path-bytes file-path-bytes
          file-status file-combined? file-old-mode file-new-mode file-old-blob file-new-blob file-binary?
          file-header file-hunks
          hunk? hunk-old-start hunk-old-count hunk-new-start hunk-new-count hunk-heading hunk-tail hunk-lines
          line? line-kind line-prefix line-bytes line-no-newline?)
  (import (chezscheme))

  ;; A job hands back plain data, so files, hunks and lines are vectors
  ;; tagged in their first slot.
  (define (file? v) (and (vector? v) (fx= (vector-length v) 14) (eq? (vector-ref v 0) 'diff-file)))
  (define (file-old-path f) (vector-ref f 1))
  (define (file-new-path f) (vector-ref f 2))
  (define (file-old-path-bytes f) (vector-ref f 3))
  (define (file-new-path-bytes f) (vector-ref f 4))
  (define (file-status f) (vector-ref f 5))
  (define (file-combined? f) (vector-ref f 6))
  (define (file-old-mode f) (vector-ref f 7))
  (define (file-new-mode f) (vector-ref f 8))
  (define (file-old-blob f) (vector-ref f 9))
  (define (file-new-blob f) (vector-ref f 10))
  (define (file-binary? f) (vector-ref f 11))
  (define (file-header f) (vector-ref f 12))
  (define (file-hunks f) (vector-ref f 13))
  (define (file-path f) (or (file-new-path f) (file-old-path f)))
  (define (file-path-bytes f) (or (file-new-path-bytes f) (file-old-path-bytes f)))

  (define (hunk? v) (and (vector? v) (fx= (vector-length v) 8) (eq? (vector-ref v 0) 'diff-hunk)))
  (define (hunk-old-start h) (vector-ref h 1))
  (define (hunk-old-count h) (vector-ref h 2))
  (define (hunk-new-start h) (vector-ref h 3))
  (define (hunk-new-count h) (vector-ref h 4))
  (define (hunk-heading h) (vector-ref h 5))
  (define (hunk-tail h) (vector-ref h 6))
  (define (hunk-lines h) (vector-ref h 7))

  (define (line? v) (and (vector? v) (fx= (vector-length v) 5) (eq? (vector-ref v 0) 'diff-line)))
  (define (line-kind l) (vector-ref l 1))
  (define (line-prefix l) (vector-ref l 2))
  (define (line-bytes l) (vector-ref l 3))
  (define (line-no-newline? l) (vector-ref l 4))

  (define (slice bv start end)
    (let ([out (make-bytevector (fx- end start))])
      (bytevector-copy! bv start out 0 (fx- end start))
      out))

  (define (starts-with? bv prefix)
    (let ([n (string-length prefix)])
      (and (fx>= (bytevector-length bv) n)
           (let loop ([i 0])
             (or (fx= i n)
                 (and (fx= (bytevector-u8-ref bv i) (char->integer (string-ref prefix i)))
                      (loop (fx+ i 1))))))))

  (define (after bv prefix) (slice bv (string-length prefix) (bytevector-length bv)))

  (define (byte-index bv byte from)
    (let ([n (bytevector-length bv)])
      (let loop ([i from])
        (cond
          [(fx= i n) #f]
          [(fx= (bytevector-u8-ref bv i) byte) i]
          [else (loop (fx+ i 1))]))))

  (define (lines-of output)
    (let ([n (bytevector-length output)])
      (let loop ([start 0] [acc '()])
        (cond
          [(fx= start n) (reverse acc)]
          [(byte-index output 10 start) => (lambda (i) (loop (fx+ i 1) (cons (slice output start i) acc)))]
          [else (reverse (cons (slice output start n) acc))]))))

  (define (text bv) (utf8->string bv))

  (define (fail line)
    (error 'diff:parse "not a unified diff" (text line)))

  ;; git C-quotes a path holding a control byte, " or \, whatever
  ;; core.quotePath says.
  (define (unquote-at bv start)
    (let-values ([(out done) (open-bytevector-output-port)])
      (let ([n (bytevector-length bv)])
        (let loop ([i (fx+ start 1)])
          (cond
            [(fx>= i n) (values (done) n)]
            [(fx= (bytevector-u8-ref bv i) 34) (values (done) (fx+ i 1))]
            [(and (fx= (bytevector-u8-ref bv i) 92) (fx< (fx+ i 1) n))
             (let ([c (integer->char (bytevector-u8-ref bv (fx+ i 1)))])
               (case c
                 [(#\a) (put-u8 out 7) (loop (fx+ i 2))]
                 [(#\b) (put-u8 out 8) (loop (fx+ i 2))]
                 [(#\t) (put-u8 out 9) (loop (fx+ i 2))]
                 [(#\n) (put-u8 out 10) (loop (fx+ i 2))]
                 [(#\v) (put-u8 out 11) (loop (fx+ i 2))]
                 [(#\f) (put-u8 out 12) (loop (fx+ i 2))]
                 [(#\r) (put-u8 out 13) (loop (fx+ i 2))]
                 [(#\" #\\) (put-u8 out (char->integer c)) (loop (fx+ i 2))]
                 [else
                  (if (fx<= (fx+ i 4) n)
                      (begin
                        (put-u8 out (fxand 255 (string->number (text (slice bv (fx+ i 1) (fx+ i 4))) 8)))
                        (loop (fx+ i 4)))
                      (values (done) n))]))]
            [else (put-u8 out (bytevector-u8-ref bv i)) (loop (fx+ i 1))])))))

  (define (unquote-path bv)
    (if (and (fx> (bytevector-length bv) 0) (fx= (bytevector-u8-ref bv 0) 34))
        (let-values ([(path end) (unquote-at bv 0)]) path)
        bv))

  ;; An unquoted name on a --- or +++ line ends at a TAB: git adds one
  ;; after a name holding a space, and diff -u one before the date. A
  ;; path holding a TAB is always quoted.
  (define (name-field bv)
    (if (and (fx> (bytevector-length bv) 0) (fx= (bytevector-u8-ref bv 0) 34))
        (unquote-path bv)
        (let ([tab (byte-index bv 9 0)])
          (if tab (slice bv 0 tab) bv))))

  (define (dev-null? bv) (equal? bv (string->utf8 "/dev/null")))

  (define (strip-prefix bv prefix)
    (if (starts-with? bv prefix) (after bv prefix) bv))

  ;; The names of a diff --git line, for a file with no --- and +++
  ;; lines: a quoted name ends at its quote; two unquoted names are the
  ;; same path when nothing renamed it.
  (define (git-line-names rest)
    (define (second-from i)
      (let ([i (if (and (fx< i (bytevector-length rest)) (fx= (bytevector-u8-ref rest i) 32)) (fx+ i 1) i)])
        (unquote-path (slice rest i (bytevector-length rest)))))
    (cond
      [(and (fx> (bytevector-length rest) 0) (fx= (bytevector-u8-ref rest 0) 34))
       (let-values ([(first end) (unquote-at rest 0)])
         (values first (second-from end)))]
      [else
       (let* ([n (bytevector-length rest)] [half (fxquotient (fx- n 1) 2)])
         (if (and (fx= (fx+ half half 1) n)
                  (fx= (bytevector-u8-ref rest half) 32)
                  (equal? (slice rest 2 half) (slice rest (fx+ half 3) n)))
             (values (slice rest 0 half) (slice rest (fx+ half 1) n))
             (let loop ([i (fx- n 3)])
               (cond
                 [(fx< i 0) (values rest rest)]
                 [(and (fx= (bytevector-u8-ref rest i) 32) (starts-with? (slice rest (fx+ i 1) n) "b/"))
                  (values (slice rest 0 i) (slice rest (fx+ i 1) n))]
                 [else (loop (fx- i 1))]))))]))

  (define (digits bv i)
    (let loop ([j i] [v 0])
      (if (and (fx< j (bytevector-length bv)) (fx<= 48 (bytevector-u8-ref bv j) 57))
          (loop (fx+ j 1) (+ (* v 10) (fx- (bytevector-u8-ref bv j) 48)))
          (values (and (fx> j i) v) j))))

  (define (range-at bv i)
    (let-values ([(start j) (digits bv i)])
      (cond
        [(not start) (values #f #f i)]
        [(and (fx< j (bytevector-length bv)) (fx= (bytevector-u8-ref bv j) 44))
         (let-values ([(count k) (digits bv (fx+ j 1))])
           (if count (values start count k) (values #f #f i)))]
        [else (values start 1 j)])))

  (define (at-byte? bv i byte) (and (fx< i (bytevector-length bv)) (fx= (bytevector-u8-ref bv i) byte)))

  ;; A combined heading, "@@@ -A,B -C,D +E,F @@@", has one @ more than
  ;; its parents.
  (define (hunk-heading-parts bv)
    (let ([ats (let loop ([i 0]) (if (at-byte? bv i 64) (loop (fx+ i 1)) i))])
      (if (fx< ats 2)
          (values #f #f #f #f)
           (let loop ([i ats] [olds '()])
             (cond
               [(and (at-byte? bv i 32) (at-byte? bv (fx+ i 1) 45))
                (let-values ([(s c j) (range-at bv (fx+ i 2))])
                  (if s (loop j (cons (cons s c) olds)) (values #f #f #f #f)))]
               [(and (at-byte? bv i 32) (at-byte? bv (fx+ i 1) 43) (fx= (length olds) (fx- ats 1)))
                (let-values ([(s c j) (range-at bv (fx+ i 2))])
                  (if (and s (at-byte? bv j 32))
                      (let close ([k (fx+ j 1)] [n 0])
                        (cond
                          [(fx= n ats) (values (fx- ats 1) (car (reverse olds)) (cons s c) (slice bv k (bytevector-length bv)))]
                          [(at-byte? bv k 64) (close (fx+ k 1) (fx+ n 1))]
                          [else (values #f #f #f #f)]))
                      (values #f #f #f #f)))]
               [else (values #f #f #f #f)])))))

  (define (blob-names bv)
    (let* ([rest (after bv "index ")]
           [space (byte-index rest 32 0)]
           [names (if space (slice rest 0 space) rest)]
           [dots (let loop ([i 0])
                   (cond
                     [(fx>= (fx+ i 1) (bytevector-length names)) #f]
                     [(and (fx= (bytevector-u8-ref names i) 46) (fx= (bytevector-u8-ref names (fx+ i 1)) 46)) i]
                     [else (loop (fx+ i 1))]))])
      (if dots
          (let ([old (slice names 0 dots)])
            (values (text (let ([comma (byte-index old 44 0)]) (if comma (slice old 0 comma) old)))
                    (text (slice names (fx+ dots 2) (bytevector-length names)))
                    (and space (text (slice rest (fx+ space 1) (bytevector-length rest))))))
          (values #f #f #f))))

  (define (type-of mode) (and mode (fx>= (string-length mode) 3) (substring mode 0 3)))

  (define-record-type reading
    (fields kind (mutable header) (mutable hunks)
            (mutable old-name) (mutable new-name) (mutable git-old) (mutable git-new)
            (mutable rename-from) (mutable rename-to) (mutable copy?)
            (mutable added?) (mutable deleted?) (mutable old-mode) (mutable new-mode)
            (mutable old-blob) (mutable new-blob) (mutable binary?) (mutable unmerged-path)))

  (define (new-reading kind first-line)
    (make-reading kind (list first-line) '() #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))

  (define (join-lines lines)
    (let-values ([(out done) (open-bytevector-output-port)])
      (for-each (lambda (l) (put-bytevector out l) (put-u8 out 10)) lines)
      (done)))

  (define (finish r)
    (let* ([kind (reading-kind r)]
           [git? (eq? kind 'git)]
           [combined? (memq kind '(combined unmerged))]
           [old-name (reading-old-name r)]
           [new-name (reading-new-name r)]
           [old-bytes (cond
                        [(reading-unmerged-path r)]
                        [(reading-rename-from r)]
                        [(and old-name (dev-null? old-name)) #f]
                        [old-name (if git? (strip-prefix old-name "a/") old-name)]
                        [(reading-added? r) #f]
                        [(reading-git-old r) (strip-prefix (reading-git-old r) "a/")]
                        [else #f])]
           [new-bytes (cond
                        [(reading-unmerged-path r)]
                        [(reading-rename-to r)]
                        [(and new-name (dev-null? new-name)) #f]
                        [new-name (if git? (strip-prefix new-name "b/") new-name)]
                        [(reading-deleted? r) #f]
                        [(reading-git-new r) (strip-prefix (reading-git-new r) "b/")]
                        [else #f])]
           [status (cond
                     [combined? 'unmerged]
                     [(or (reading-added? r) (and old-name (dev-null? old-name))) 'added]
                     [(or (reading-deleted? r) (and new-name (dev-null? new-name))) 'deleted]
                     [(reading-rename-from r) (if (reading-copy? r) 'copied 'renamed)]
                     [(and (reading-old-mode r) (reading-new-mode r)
                           (not (equal? (type-of (reading-old-mode r)) (type-of (reading-new-mode r)))))
                      'type-changed]
                     [else 'modified])])
      (vector 'diff-file
              (and old-bytes (text old-bytes)) (and new-bytes (text new-bytes)) old-bytes new-bytes
              status (and combined? #t)
              (reading-old-mode r) (reading-new-mode r) (reading-old-blob r) (reading-new-blob r)
              (reading-binary? r)
              (if (eq? kind 'unmerged) #vu8() (join-lines (reverse (reading-header r))))
              (reverse (reading-hunks r)))))

  (define (header-line! r line)
    (reading-header-set! r (cons line (reading-header r)))
    (cond
      [(starts-with? line "--- ") (reading-old-name-set! r (name-field (after line "--- ")))]
      [(starts-with? line "+++ ") (reading-new-name-set! r (name-field (after line "+++ ")))]
      [(eq? (reading-kind r) 'plain)]
      [(starts-with? line "rename from ") (reading-rename-from-set! r (unquote-path (after line "rename from ")))]
      [(starts-with? line "rename to ") (reading-rename-to-set! r (unquote-path (after line "rename to ")))]
      [(starts-with? line "copy from ")
       (reading-copy?-set! r #t)
       (reading-rename-from-set! r (unquote-path (after line "copy from ")))]
      [(starts-with? line "copy to ") (reading-rename-to-set! r (unquote-path (after line "copy to ")))]
      [(starts-with? line "new file mode ")
       (reading-added?-set! r #t)
       (reading-new-mode-set! r (text (after line "new file mode ")))]
      [(starts-with? line "deleted file mode ")
       (reading-deleted?-set! r #t)
       (reading-old-mode-set! r (text (after line "deleted file mode ")))]
      [(starts-with? line "old mode ") (reading-old-mode-set! r (text (after line "old mode ")))]
      [(starts-with? line "new mode ") (reading-new-mode-set! r (text (after line "new mode ")))]
      [(starts-with? line "index ")
       (let-values ([(old new mode) (blob-names line)])
         (reading-old-blob-set! r old)
         (reading-new-blob-set! r new)
         (when (and mode (not (eq? (reading-kind r) 'combined)))
           (reading-old-mode-set! r mode)
           (reading-new-mode-set! r mode)))]
      [(or (starts-with? line "Binary files ") (starts-with? line "GIT binary patch"))
       (reading-binary?-set! r #t)]))

  (define (prefix-kind prefix)
    (let ([n (bytevector-length prefix)])
      (let loop ([i 0] [kind 'context])
        (if (fx= i n)
            kind
            (case (bytevector-u8-ref prefix i)
              [(43) 'added]
              [(45) 'removed]
              [else (loop (fx+ i 1) kind)])))))

  (define (make-line prefix bytes) (vector 'diff-line (prefix-kind prefix) prefix bytes #f))

  (define (with-no-newline line)
    (vector 'diff-line (line-kind line) (line-prefix line) (line-bytes line) #t))

  (define space-prefix (bytevector 32))

  (define (spaces n) (make-bytevector n 32))

  (define (file-start line)
    (cond
      [(starts-with? line "diff --git ")
       (let ([r (new-reading 'git line)])
         (let-values ([(old new) (git-line-names (after line "diff --git "))])
           (reading-git-old-set! r old)
           (reading-git-new-set! r new))
         r)]
      [(or (starts-with? line "diff --cc ") (starts-with? line "diff --combined "))
       (let ([r (new-reading 'combined line)])
         (let ([path (unquote-path (after line (if (starts-with? line "diff --cc ") "diff --cc " "diff --combined ")))])
           (reading-old-name-set! r (bytevector-append (string->utf8 "a/") path))
           (reading-new-name-set! r (bytevector-append (string->utf8 "b/") path))
           (reading-unmerged-path-set! r path))
         r)]
      [(starts-with? line "* Unmerged path ")
       (let ([r (new-reading 'unmerged line)])
         (reading-unmerged-path-set! r (unquote-path (after line "* Unmerged path ")))
         r)]
      [(starts-with? line "--- ")
       (let ([r (new-reading 'plain line)])
         (reading-header-set! r '())
         (header-line! r line)
         r)]
      [(starts-with? line "diff ") (new-reading 'plain line)]
      [else #f]))

  (define (bytevector-append a b)
    (let ([out (make-bytevector (fx+ (bytevector-length a) (bytevector-length b)))])
      (bytevector-copy! a 0 out 0 (bytevector-length a))
      (bytevector-copy! b 0 out (bytevector-length a) (bytevector-length b))
      out))

  ;; Lines split at LF alone, so a CR before it stays part of its line. A
  ;; hunk's lines are counted against its heading, so a removed line that
  ;; reads "--- x" is never taken for the next file's header.
  (define (parse-diff output)
    (unless (bytevector? output)
      (assertion-violation 'diff:parse "not a bytevector" output))
    (let loop ([lines (lines-of output)] [files '()] [r #f])
      (define (done-file) (if r (cons (finish r) files) files))
      (cond
        [(null? lines) (reverse (done-file))]
        [else
         (let* ([line (car lines)] [kind (and r (reading-kind r))])
           (cond
             [(and (memq kind '(git combined plain))
                   (not (and (eq? kind 'plain) (not (and (reading-old-name r) (reading-new-name r)))))
                   (or (starts-with? line "@@ ") (and (eq? kind 'combined) (starts-with? line "@@@"))))
              (let-values ([(parents old new tail) (hunk-heading-parts line)])
                (unless (and parents (if (eq? kind 'combined) (fx>= parents 2) (fx= parents 1)))
                  (fail line))
                (let-values ([(hunk-lines rest) (if (fx= parents 1)
                                                     (counted-lines (cdr lines) (cdr old) (cdr new) line)
                                                     (combined-lines (cdr lines) parents))])
                  (reading-hunks-set! r (cons (vector 'diff-hunk (car old) (cdr old) (car new) (cdr new) line tail hunk-lines)
                                              (reading-hunks r)))
                  (loop rest files r)))]
             [(and (memq kind '(git combined)) (null? (reading-hunks r)) (not (git-file-start? line)))
              (header-line! r line)
              (loop (cdr lines) files r)]
             [(and (eq? kind 'plain) (null? (reading-hunks r)) (not (and (reading-old-name r) (reading-new-name r))))
              (header-line! r line)
              (loop (cdr lines) files r)]
             [(file-start line)
              => (lambda (next) (loop (cdr lines) (done-file) next))]
             [else (fail line)]))])))

  (define (git-file-start? line)
    (or (starts-with? line "diff --git ") (starts-with? line "diff --cc ") (starts-with? line "diff --combined ")
        (starts-with? line "* Unmerged path ")))

  (define (marker? line) (and (fx> (bytevector-length line) 0) (fx= (bytevector-u8-ref line 0) 92)))

  (define (attach-marker acc heading)
    (if (null? acc) (fail heading) (cons (with-no-newline (car acc)) (cdr acc))))

  (define (counted-lines lines old new heading)
    (let loop ([lines lines] [old old] [new new] [acc '()])
      (cond
        [(and (pair? lines) (marker? (car lines)))
         (loop (cdr lines) old new (attach-marker acc heading))]
        [(and (fx= old 0) (fx= new 0)) (values (list->vector (reverse acc)) lines)]
        [(null? lines) (fail heading)]
        [else
         (let* ([line (car lines)]
                [n (bytevector-length line)]
                [c (if (fx= n 0) 32 (bytevector-u8-ref line 0))]
                [prefix (bytevector c)]
                [bytes (if (fx= n 0) #vu8() (slice line 1 n))])
           (case c
             [(32) (if (and (fx> old 0) (fx> new 0))
                       (loop (cdr lines) (fx- old 1) (fx- new 1) (cons (make-line space-prefix bytes) acc))
                       (fail line))]
             [(45) (if (fx> old 0) (loop (cdr lines) (fx- old 1) new (cons (make-line prefix bytes) acc)) (fail line))]
             [(43) (if (fx> new 0) (loop (cdr lines) old (fx- new 1) (cons (make-line prefix bytes) acc)) (fail line))]
             [else (fail line)]))])))

  (define (combined-lines lines parents)
    (let loop ([lines lines] [acc '()])
      (cond
        [(null? lines) (values (list->vector (reverse acc)) lines)]
        [(marker? (car lines)) (loop (cdr lines) (attach-marker acc (car lines)))]
        [else
         (let* ([line (car lines)] [n (bytevector-length line)])
           (cond
             [(fx= n 0) (loop (cdr lines) (cons (make-line (spaces parents) #vu8()) acc))]
             [(and (fx>= n parents)
                   (let check ([i 0])
                     (or (fx= i parents) (and (memv (bytevector-u8-ref line i) '(32 43 45)) (check (fx+ i 1))))))
              (loop (cdr lines) (cons (make-line (slice line 0 parents) (slice line parents n)) acc))]
             [else (values (list->vector (reverse acc)) lines)]))]))))
