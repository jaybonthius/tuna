(import (tuna))
(use-plugin git)
(import (diff) (processes))

(define home (getenv "HOME"))

(define (bytes . parts)
  (let-values ([(out done) (open-bytevector-output-port)])
    (for-each (lambda (p) (if (string? p) (put-bytevector out (string->utf8 p)) (put-u8 out p))) parts)
    (done)))

(define (join parts)
  (let-values ([(out done) (open-bytevector-output-port)])
    (for-each (lambda (p) (put-bytevector out p)) parts)
    (done)))

(define (slice bv start end)
  (let ([out (make-bytevector (- end start))])
    (bytevector-copy! bv start out 0 (- end start))
    out))

(define (octal path)
  (apply string-append
         (map (lambda (b) (let ([o (number->string b 8)]) (string-append "\\" (make-string (- 3 (string-length o)) #\0) o)))
              (bytevector->u8-list path))))

(define (shell folder script . input)
  (let-values ([(status out err)
                (processes:run "sh" (list "-c" script) (if (null? input) #f (car input))
                               (processes:options [directory folder] [separate-stderr #t]))])
    (values status out)))

(define (sh folder script)
  (let-values ([(status out) (shell folder (string-append "set -e; " script))])
    (unless (eqv? status 0)
      (error 'sh "failed" script))))

(define (path-bytes p) (if (string? p) (string->utf8 p) p))

(define (write-file! folder path data)
  (shell folder (string-append "p=$(printf '" (octal (path-bytes path)) "'); mkdir -p \"$(dirname -- \"$p\")\"; cat > \"$p\"")
         (if (string? data) (string->utf8 data) data))
  (void))

(define (read-worktree folder path)
  (let-values ([(status out)
                (shell folder (string-append "p=$(printf '" (octal (path-bytes path)) "'); [ -e \"$p\" ] || exit 3; cat -- \"$p\""))])
    (and (eqv? status 0) out)))

(define (split-at-nul bv)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (bytevector-length bv)) (reverse acc)]
      [(= (bytevector-u8-ref bv i) 0) (loop (+ i 1) (+ i 1) (cons (slice bv start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (index-blob repo path)
  (let loop ([entries (split-at-nul (git:query repo '("ls-files" "-s" "-z")))])
    (cond
      [(null? entries) #f]
      [else
       (let* ([e (car entries)]
              [tab (let find ([i 0]) (if (= (bytevector-u8-ref e i) 9) i (find (+ i 1))))])
         (if (equal? (slice e (+ tab 1) (bytevector-length e)) path)
             (utf8->string (slice e 7 47))
             (loop (cdr entries))))])))

(define (read-index repo path)
  (let ([blob (index-blob repo path)])
    (and blob (git:query repo (list "cat-file" "blob" blob)))))

(define (fresh name)
  (let ([folder (string-append home "/" name)])
    (sh home (string-append "rm -rf " name " && mkdir " name))
    (sh folder "git init -q && git config user.name T && git config user.email t@x && git config core.autocrlf false")
    folder))

(define (repository-of folder) (git:find-repository folder))

(define (split text)
  (if (not text)
      '()
      (let loop ([start 0] [acc '()])
        (cond
          [(= start (bytevector-length text)) (reverse acc)]
          [else
           (let find ([i start])
             (cond
               [(= i (bytevector-length text)) (reverse (cons (slice text start i) acc))]
               [(= (bytevector-u8-ref text i) 10) (loop (+ i 1) (cons (slice text start (+ i 1)) acc))]
               [else (find (+ i 1))]))]))))

(define (region hunk chosen reverse?)
  (let* ([kept (let loop ([i 0] [acc '()])
                 (if (= i (vector-length (diff:hunk-lines hunk)))
                     (reverse acc)
                     (let* ([l (vector-ref (diff:hunk-lines hunk) i)] [selected? (memv i chosen)]
                            [keep? (case (diff:line-kind l)
                                     [(context) #t]
                                     [(removed) (if reverse? selected? (not selected?))]
                                     [else (if reverse? (not selected?) selected?)])])
                       (loop (+ i 1) (if keep? (cons l acc) acc)))))]
         [n (length kept)])
    (let loop ([ls kept] [j 0] [acc '()])
      (if (null? ls)
          (reverse acc)
          (let ([l (car ls)])
            (loop (cdr ls) (+ j 1)
                  (cons (if (and (diff:line-no-newline? l) (= j (- n 1)))
                            (diff:line-bytes l)
                            (join (list (diff:line-bytes l) #vu8(10))))
                        acc)))))))

(define (expected target hunk chosen reverse?)
  (let* ([t (split target)]
         [start (if reverse? (diff:hunk-new-start hunk) (diff:hunk-old-start hunk))]
         [count (if reverse? (diff:hunk-new-count hunk) (diff:hunk-old-count hunk))]
         [first (if (> count 0) (- start 1) start)])
    (join (append (list-head t first) (region hunk chosen reverse?) (list-tail t (+ first count))))))

(define (change-indexes hunk)
  (let loop ([i (- (vector-length (diff:hunk-lines hunk)) 1)] [acc '()])
    (if (< i 0)
        acc
        (loop (- i 1) (if (eq? (diff:line-kind (vector-ref (diff:hunk-lines hunk) i)) 'context) acc (cons i acc))))))

(define operations
  '((stage #f #f ("--cached") (index))
    (unstage #t #t ("--reverse" "--cached") (index))
    (discard #f #t ("--reverse") (worktree))
    (discard-staged #t #t ("--reverse" "--index") (index worktree))))

(define (diff-of repo staged?) (git:diff repo (if staged? '("--cached") '())))

(define (file-of repo staged? path)
  (find (lambda (f) (equal? (diff:file-path-bytes f) path)) (diff-of repo staged?)))

(define failures '())
(define trials 0)

(define (failed! label patch why)
  (set! failures (cons (list label why (utf8->string patch)) failures)))

(define (trial! folder op path selection label)
  (let* ([repo (repository-of folder)]
         [spec (cdr (assq op operations))]
         [staged? (car spec)] [reverse? (cadr spec)] [arguments (caddr spec)] [targets (cadddr spec)]
         [file (file-of repo staged? path)])
    (when (and file (pair? (diff:file-hunks file)))
      (set! trials (+ trials 1))
      (let* ([before (list (cons 'index (read-index repo path)) (cons 'worktree (read-worktree folder path)))]
             [hunks (diff:file-hunks file)])
        (let-values ([(patch want)
                      (case (car selection)
                        [(lines)
                         (let* ([h (list-ref hunks (cadr selection))] [first (caddr selection)] [last (cadddr selection)]
                                [chosen (filter (lambda (i) (<= first i last)) (change-indexes h))])
                           (values ((if reverse? diff:reverse-lines-patch diff:lines-patch) file h first last)
                                   (map (lambda (t) (cons t (expected (cdr (assq t before)) h chosen reverse?))) targets)))]
                        [else
                         (let ([hs (list-head (list-tail hunks (cadr selection)) (+ 1 (- (caddr selection) (cadr selection))))])
                           (values ((if reverse? diff:reverse-hunks-patch diff:hunks-patch) file hs)
                                   (map (lambda (t)
                                          (cons t (fold-left (lambda (text h) (expected text h (change-indexes h) reverse?))
                                                             (cdr (assq t before))
                                                             (list-sort (lambda (a b) (> (diff:hunk-old-start a) (diff:hunk-old-start b))) hs))))
                                        targets)))])])
          (let ([refused (guard (c [(git:failed-condition? c) (git:failure-summary c)])
                           (git:apply repo patch arguments)
                           #f)])
            (cond
              [refused (failed! label patch refused)]
              [else
               (let ([got (list (cons 'index (read-index repo path)) (cons 'worktree (read-worktree folder path)))])
                 (for-each
                   (lambda (t)
                     (unless (equal? (or (cdr (assq t got)) #vu8()) (cdr (assq t want)))
                       (failed! label patch (list 'wrong t (cdr (assq t want)) (cdr (assq t got))))))
                   targets))])))))))

(define (selections file)
  (let ([hunks (diff:file-hunks file)])
    (append
      (let loop ([hs hunks] [k 0] [acc '()])
        (if (null? hs)
            (reverse acc)
            (let ([changes (change-indexes (car hs))])
              (loop (cdr hs) (+ k 1)
                    (append (reverse
                              (let outer ([as changes] [acc '()])
                                (if (null? as)
                                    (reverse acc)
                                    (outer (cdr as) (append (reverse (map (lambda (b) (list 'lines k (car as) b)) as)) acc)))))
                            acc)))))
      (let outer ([a 0] [acc '()])
        (if (= a (length hunks))
            (reverse acc)
            (outer (+ a 1)
                   (let inner ([b a] [acc acc])
                     (if (= b (length hunks)) acc (inner (+ b 1) (cons (list 'hunks a b) acc))))))))))

(define (snapshot! folder name) (sh home (string-append "tar cf " name ".tar -C " folder " .")))

(define (restore! folder name)
  (sh home (string-append "rm -rf " folder " && mkdir " folder " && tar xf " name ".tar -C " folder))
  (shell folder "git update-index -q --refresh"))

(define (run-edges! names)
  (set! failures '())
  (set! trials 0)
  (for-each
    (lambda (name)
      (let* ([folder (fresh (symbol->string name))]
             [case-of (cdr (assq name edges))]
             [setup (case-of folder)]
             [path (path-bytes (car setup))])
        (snapshot! folder (symbol->string name))
        (for-each
          (lambda (op)
            (restore! folder (symbol->string name))
            (let ([file (file-of (repository-of folder) (cadr (assq op operations)) path)])
              (if (not file)
                  (failed! (list name op) #vu8() "the diff names no such file")
                  (for-each
                    (lambda (selection)
                      (restore! folder (symbol->string name))
                      (trial! folder op path selection (list name op selection)))
                    (selections file)))))
          (cdr setup))))
    names)
  (list 'trials trials 'failures (reverse failures)))

(define (lines-text n make) (apply bytes (map make (iota n))))

(define (repeated n line) (apply string-append (make-list n line)))

(define edges
  (list
    (cons 'no-newline-append
          (lambda (d)
            (write-file! d "f.txt" "a\nb\nc\nd") (sh d "git add . && git commit -qm c")
            (write-file! d "f.txt" "a\nb\nc\nd\nD") '("f.txt" stage discard)))
    (cons 'no-newline-change-last
          (lambda (d)
            (write-file! d "f.txt" "a\nb\nc\nd") (sh d "git add . && git commit -qm c")
            (write-file! d "f.txt" "a\nb\nX\nD") '("f.txt" stage discard)))
    (cons 'no-newline-added
          (lambda (d)
            (write-file! d "f.txt" "a\nb\nc\n") (sh d "git add . && git commit -qm c")
            (write-file! d "f.txt" "a\nB\nc\nd") '("f.txt" stage discard)))
    (cons 'no-newline-removed
          (lambda (d)
            (write-file! d "f.txt" "a\nb\nc") (sh d "git add . && git commit -qm c")
            (write-file! d "f.txt" "a\nB\n") '("f.txt" stage discard)))
    (cons 'no-newline-staged
          (lambda (d)
            (write-file! d "f.txt" "a\nb\nc\nd") (sh d "git add . && git commit -qm c")
            (write-file! d "f.txt" "a\nB\nc\nd\nD") (sh d "git add .") '("f.txt" unstage discard-staged)))
    (cons 'crlf
          (lambda (d)
            (write-file! d "c.txt" (lines-text 29 (lambda (i) (format "l~a\r\n" (+ i 1)))))
            (sh d "git add . && git commit -qm c")
            (write-file! d "c.txt"
                         (lines-text 30 (lambda (i)
                                          (cond
                                            [(= i 2) "L3\r\n"]
                                            [(= i 20) "new\r\n"]
                                            [(= i 25) "L25\n"]
                                            [else (format "l~a\r\n" (if (< i 20) (+ i 1) i))]))))
            '("c.txt" stage discard)))
    (cons 'crlf-staged
          (lambda (d)
            (write-file! d "c.txt" (lines-text 29 (lambda (i) (format "l~a\r\n" (+ i 1)))))
            (sh d "git add . && git commit -qm c")
            (write-file! d "c.txt"
                         (lines-text 28 (lambda (i)
                                          (cond
                                            [(= i 2) "L3\r\n"]
                                            [else (format "l~a\r\n" (if (< i 20) (+ i 1) (+ i 2)))]))))
            (sh d "git add .") '("c.txt" unstage discard-staged)))
    (cons 'rename-two-hunks
          (lambda (d)
            (write-file! d "old.txt" (lines-text 20 (lambda (i) (format "~a\n" (+ i 1)))))
            (sh d "git add . && git commit -qm c && git mv old.txt new.txt")
            (write-file! d "new.txt" (lines-text 20 (lambda (i)
                                                      (cond [(= i 1) "TWO\n"] [(= i 18) "NINETEEN\n"] [else (format "~a\n" (+ i 1))]))))
            (sh d "git add .") '("new.txt" unstage discard-staged)))
    (cons 'new-file-staged
          (lambda (d)
            (write-file! d "keep.txt" "k\n") (sh d "git add . && git commit -qm c")
            (write-file! d "n.txt" "one\ntwo\nthree\n") (sh d "git add n.txt") '("n.txt" unstage discard-staged)))
    (cons 'new-file-intent-to-add
          (lambda (d)
            (write-file! d "keep.txt" "k\n") (sh d "git add . && git commit -qm c")
            (write-file! d "n.txt" "one\ntwo\nthree") (sh d "git add -N n.txt") '("n.txt" stage discard)))
    (cons 'deleted-unstaged
          (lambda (d)
            (write-file! d "g.txt" "one\ntwo\nthree\n") (sh d "git add . && git commit -qm c && rm g.txt")
            '("g.txt" stage discard)))
    (cons 'deleted-staged
          (lambda (d)
            (write-file! d "g.txt" "one\ntwo\nthree\n") (sh d "git add . && git commit -qm c && git rm -q g.txt")
            '("g.txt" unstage discard-staged)))
    (cons 'mode-change
          (lambda (d)
            (write-file! d "m.sh" (lines-text 20 (lambda (i) (format "~a\n" (+ i 1)))))
            (sh d "git add . && git commit -qm c")
            (write-file! d "m.sh" (lines-text 20 (lambda (i)
                                                   (cond [(= i 1) "TWO\n"] [(= i 18) "NINETEEN\n"] [else (format "~a\n" (+ i 1))]))))
            (sh d "chmod 755 m.sh") '("m.sh" stage discard)))
    (cons 'blank-lines
          (lambda (d)
            (sh d "git config diff.suppressBlankEmpty true")
            (write-file! d "b.txt" "a\n\n\nb\n\nc\n") (sh d "git add . && git commit -qm c")
            (write-file! d "b.txt" "a\n\nB\n\n\nc\n\n") '("b.txt" stage discard)))
    (cons 'latin1
          (lambda (d)
            (write-file! d "l.txt" (bytes "un\ncaf" #xe9 " au lait\ntrois\nquatre\n")) (sh d "git add . && git commit -qm c")
            (write-file! d "l.txt" (bytes "un\ncaf" #xe9 " au lait\nTROIS\ncr" #xe8 "me\nquatre\nna" #xef "ve\n"))
            '("l.txt" stage discard)))
    (cons 'latin1-staged
          (lambda (d)
            (write-file! d "l.txt" (bytes "un\ncaf" #xe9 "\ntrois\n")) (sh d "git add . && git commit -qm c")
            (write-file! d "l.txt" (bytes "un\ncaf" #xe9 "\nd" #xe9 "j" #xe0 "\ntrois\n" #xff #xfe "\n")) (sh d "git add .")
            '("l.txt" unstage discard-staged)))
    (cons 'whitespace-fix
          (lambda (d)
            (sh d "git config apply.whitespace fix")
            (write-file! d "w.txt" "a\nb\nc\n") (sh d "git add . && git commit -qm c")
            (write-file! d "w.txt" "a\nnew line   \nb\t\nc\n  \n") '("w.txt" stage discard)))
    (cons 'whitespace-error
          (lambda (d)
            (sh d "git config apply.whitespace error")
            (write-file! d "w.txt" "a\nb\nc\n") (sh d "git add . && git commit -qm c")
            (write-file! d "w.txt" "a\nnew line   \nb\t\nc\n") (sh d "git add .") '("w.txt" unstage discard-staged)))
    (cons 'other-prefixes
          (lambda (d)
            (sh d "git config diff.srcPrefix old/ && git config diff.dstPrefix new/")
            (write-file! d "p.txt" "one\ntwo\nthree\n") (sh d "git add . && git commit -qm c")
            (write-file! d "p.txt" "one\nTWO\nthree\nfour\n") '("p.txt" stage discard)))
    (cons 'textconv
          (lambda (d)
            (sh d "git config diff.upper.textconv 'tr a-z A-Z <'")
            (write-file! d ".gitattributes" "*.up diff=upper\n")
            (write-file! d "t.up" "one\ntwo\nthree\n") (sh d "git add . && git commit -qm c")
            (write-file! d "t.up" "one\ntwo2\nthree\nfour\n") '("t.up" stage discard)))
    (cons 'quoted-tab
          (lambda (d)
            (write-file! d "tab\there.txt" "one\ntwo\n") (sh d "git add . && git commit -qm c")
            (write-file! d "tab\there.txt" "one\nTWO\nthree\n") '("tab\there.txt" stage discard)))
    (cons 'quoted-quote-and-backslash
          (lambda (d)
            (write-file! d "quo\"te\\back.txt" "one\ntwo\n") (sh d "git add . && git commit -qm c")
            (write-file! d "quo\"te\\back.txt" "one\nTWO\nthree\n") (sh d "git add .")
            '("quo\"te\\back.txt" unstage discard-staged)))
    (cons 'latin1-path
          (lambda (d)
            (let ([p (bytes "caf" #xe9 ".txt")])
              (write-file! d p "one\ntwo\n") (sh d "git add . && git commit -qm c")
              (write-file! d p "one\nTWO\nthree\n") (list p 'stage 'discard))))
    (cons 'space-file
          (lambda (d)
            (write-file! d "my file.txt" "one\ntwo\nthree\n") (sh d "git add . && git commit -qm c")
            (write-file! d "my file.txt" "one\nTWO\nthree\nfour\n") '("my file.txt" stage discard)))
    (cons 'space-folder-staged
          (lambda (d)
            (write-file! d "my dir/f.txt" "one\ntwo\nthree\n") (sh d "git add . && git commit -qm c")
            (write-file! d "my dir/f.txt" "one\nTWO\nthree\nfour\n") (sh d "git add .")
            '("my dir/f.txt" unstage discard-staged)))
    (cons 'space-and-quote
          (lambda (d)
            (write-file! d "say \"hi\" now.txt" "one\ntwo\n") (sh d "git add . && git commit -qm c")
            (write-file! d "say \"hi\" now.txt" "one\nTWO\nthree\n") '("say \"hi\" now.txt" stage discard)))
    (cons 'space-new-file
          (lambda (d)
            (write-file! d "keep.txt" "k\n") (sh d "git add . && git commit -qm c")
            (write-file! d "new file.txt" "one\ntwo\nthree\n") (sh d "git add .")
            '("new file.txt" unstage discard-staged)))
    (cons 'space-deleted-file
          (lambda (d)
            (write-file! d "old file.txt" "one\ntwo\nthree\n") (sh d "git add . && git commit -qm c && rm 'old file.txt'")
            '("old file.txt" stage discard)))
    (cons 'repeated-lines
          (lambda (d)
            (write-file! d "r.txt" (string-append "top\n" (repeated 20 "x\n") "DEL\n" (repeated 20 "x\n")))
            (sh d "git add . && git commit -qm c")
            (write-file! d "r.txt" (string-append "top\n" (apply string-append (map (lambda (i) (format "n~a\n" i)) (iota 10))) (repeated 40 "x\n")))
            '("r.txt" stage discard)))
    (cons 'repeated-lines-staged
          (lambda (d)
            (write-file! d "r.txt" (string-append "top\n" (repeated 20 "x\n") "DEL\n" (repeated 20 "x\n")))
            (sh d "git add . && git commit -qm c")
            (write-file! d "r.txt" (string-append "top\n" (apply string-append (map (lambda (i) (format "n~a\n" i)) (iota 10))) (repeated 40 "x\n")))
            (sh d "git add .")
            '("r.txt" unstage discard-staged)))))

;; A seeded generator, so each run edits the same way.
(define seed 1)
(define (random-below n)
  (set! seed (mod (+ (* seed 1103515245) 12345) 2147483648))
  (mod (div seed 65536) n))
(define (random-unit) (/ (random-below 10000) 10000.0))
(define (choose items) (list-ref items (random-below (length items))))

(define (edit lines crlf?)
  (let ([eol (if crlf? "\r\n" "\n")])
    (let loop ([k (+ 1 (random-below 12))] [lines lines])
      (if (= k 0)
          lines
          (let ([op (choose '(insert delete replace))] [i (random-below (+ (length lines) 1))])
            (loop (- k 1)
                  (cond
                    [(or (eq? op 'insert) (null? lines))
                     (append (list-head lines i) (list (string->utf8 (format "tuna ~a~a" (random-below 1000000) eol))) (list-tail lines i))]
                    [(eq? op 'delete)
                     (let ([i (min i (- (length lines) 1))]) (append (list-head lines i) (list-tail lines (+ i 1))))]
                    [else
                     (let ([i (min i (- (length lines) 1))])
                       (append (list-head lines i) (list (string->utf8 (format "changed ~a~a" (random-below 1000000) eol)))
                               (list-tail lines (+ i 1))))])))))))

(define (strip-newlines bv)
  (let loop ([n (bytevector-length bv)])
    (if (and (> n 0) (= (bytevector-u8-ref bv (- n 1)) 10)) (loop (- n 1)) (slice bv 0 n))))

(define (to-crlf bv)
  (join (map (lambda (l)
               (let ([n (bytevector-length l)])
                 (cond
                   [(and (> n 1) (= (bytevector-u8-ref l (- n 1)) 10) (= (bytevector-u8-ref l (- n 2)) 13)) l]
                   [(and (> n 0) (= (bytevector-u8-ref l (- n 1)) 10)) (join (list (slice l 0 (- n 1)) #vu8(13 10)))]
                   [else l])))
             (split bv))))

(define (random-files! d count)
  (map (lambda (k)
         (let ([path (format "src/file-~a.ss" k)])
           (write-file! d path (lines-text (+ 20 (random-below 60)) (lambda (i) (format "(define line-~a-~a ~a)\n" k i (random-below 1000)))))
           path))
       (iota count)))

(define (run-random! name start-seed rounds steps)
  (set! failures '())
  (set! trials 0)
  (set! seed start-seed)
  (let* ([d (fresh name)] [tracked (random-files! d 12)] [repo (repository-of d)])
    (sh d "git add -A && git commit -qm base")
    (do ([r 0 (+ r 1)]) ((= r rounds))
      (let* ([chosen (let pick ([acc '()])
                       (if (= (length acc) 3) (reverse acc)
                           (let ([p (choose tracked)]) (pick (if (member p acc) acc (cons p acc))))))]
             [crlf-path (car chosen)] [nonl-path (cadr chosen)] [ren-path (caddr chosen)])
        (write-file! d crlf-path (to-crlf (read-worktree d crlf-path)))
        (write-file! d nonl-path (strip-newlines (read-worktree d nonl-path)))
        (sh d "git add -A && git commit -q --allow-empty -m round")
        (for-each
          (lambda (p)
            (let ([new (join (edit (split (read-worktree d p)) (equal? p crlf-path)))])
              (write-file! d p (if (and (equal? p nonl-path) (< (random-unit) 0.5)) (strip-newlines new) new))))
          chosen)
        (let ([moved (string-append ren-path ".moved")])
          (sh d (string-append "git mv " ren-path " " moved))
          (write-file! d moved (join (edit (split (read-worktree d moved)) #f))))
        (write-file! d (format "added-~a.txt" r) (lines-text (+ 2 (random-below 8)) (lambda (i) (format "a~a\n" i))))
        (let ([deleted (choose (filter (lambda (p) (and (not (member p chosen)) (read-worktree d p))) tracked))])
          (sh d (string-append "git rm -q " deleted)))
        (sh d "git add -A")
        (for-each (lambda (p) (write-file! d p (join (edit (split (read-worktree d p)) (equal? p crlf-path)))))
                  (list nonl-path crlf-path))
        (do ([step 0 (+ step 1)]) ((= step steps))
          (let* ([op (choose '(stage unstage discard discard-staged))]
                 [staged? (cadr (assq op operations))]
                 [files (filter (lambda (f) (and (pair? (diff:file-hunks f)) (not (diff:file-binary? f)))) (diff-of repo staged?))]
                 [files (if (eq? op 'discard-staged)
                            (let ([unstaged (map diff:file-path-bytes (diff-of repo #f))])
                              (filter (lambda (f) (not (member (diff:file-path-bytes f) unstaged))) files))
                            files)])
            (unless (null? files)
              (let* ([f (choose files)] [hunks (diff:file-hunks f)])
                (if (< (random-unit) 0.7)
                    (let* ([hi (random-below (length hunks))] [changes (change-indexes (list-ref hunks hi))]
                           [a (random-below (length changes))] [b (+ a (random-below (- (length changes) a)))])
                      (trial! d op (diff:file-path-bytes f) (list 'lines hi (list-ref changes a) (list-ref changes b))
                              (list 'round r 'step step)))
                    (let* ([a (random-below (length hunks))] [b (+ a (random-below (- (length hunks) a)))])
                      (trial! d op (diff:file-path-bytes f) (list 'hunks a b) (list 'round r 'step step))))))))
        (sh d "git reset -q --hard && git clean -qfd"))))
  (list 'trials trials 'failures (reverse failures)))
(import (console))
