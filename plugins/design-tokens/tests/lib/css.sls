#!tuna
;; Tuna's own stylesheets hold no string or comment with a brace or a
;; semicolon in it, so the reader does not look for them.

(define-record-type rule
  (sealed #t)
  (fields layer selector declarations))

(define (plugin-file name)
  (let* ([slash (let loop ([i 0]) (if (char=? (string-ref name i) #\/) i (loop (+ i 1))))]
         [plugin (substring name 0 slash)])
    (string-append (path-parent (car (command-line))) "/plugins/" plugin "/src/" name)))

(define (file-text name) (call-with-input-file (plugin-file name) get-string-all))

(define (stylesheets)
  (let ([plugins (string-append (path-parent (car (command-line))) "/plugins")])
    (list-sort string<?
      (apply append
        (map (lambda (plugin)
               (let ([folder (string-append plugins "/" plugin "/src/" plugin)])
                 (if (file-directory? folder)
                     (map (lambda (f) (string-append plugin "/" f))
                          (filter (lambda (f) (suffix? ".css" f)) (directory-list folder)))
                     '())))
             (directory-list plugins))))))

(define (prefix? p s) (and (<= (string-length p) (string-length s)) (string=? p (substring s 0 (string-length p)))))

(define (suffix? p s)
  (let ([n (string-length s)] [m (string-length p)])
    (and (<= m n) (string=? p (substring s (- n m) n)))))

(define (search s sub from)
  (let ([n (string-length sub)] [m (string-length s)])
    (let loop ([i from])
      (cond
        [(> (+ i n) m) #f]
        [(string=? (substring s i (+ i n)) sub) i]
        [else (loop (+ i 1))]))))

(define (trim s)
  (let loop ([i 0] [j (string-length s)])
    (cond
      [(and (< i j) (char-whitespace? (string-ref s i))) (loop (+ i 1) j)]
      [(and (< i j) (char-whitespace? (string-ref s (- j 1)))) (loop i (- j 1))]
      [else (substring s i j)])))

(define (without-comments s)
  (let loop ([from 0] [acc '()])
    (let ([i (search s "/*" from)])
      (if i
          (loop (+ (search s "*/" i) 2) (cons (substring s from i) acc))
          (apply string-append (reverse (cons (substring s from (string-length s)) acc)))))))

;; Splits at c outside parentheses, so a var() fallback's comma or a
;; url()'s semicolon stays whole.
(define (split s c)
  (let loop ([i 0] [from 0] [depth 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s from i) acc))]
      [(char=? (string-ref s i) #\() (loop (+ i 1) from (+ depth 1) acc)]
      [(char=? (string-ref s i) #\)) (loop (+ i 1) from (- depth 1) acc)]
      [(and (= depth 0) (char=? (string-ref s i) c)) (loop (+ i 1) (+ i 1) depth (cons (substring s from i) acc))]
      [else (loop (+ i 1) from depth acc)])))

(define (closing s open)
  (let loop ([i (+ open 1)] [depth 1])
    (case (string-ref s i)
      [(#\{) (loop (+ i 1) (+ depth 1))]
      [(#\}) (if (= depth 1) i (loop (+ i 1) (- depth 1)))]
      [else (loop (+ i 1) depth)])))

(define (declarations-of body)
  (fold-right
    (lambda (d acc)
      (let ([d (trim d)])
        (if (string=? d "")
            acc
            (let ([colon (search d ":" 0)])
              (cons (cons (trim (substring d 0 colon)) (trim (substring d (+ colon 1) (string-length d)))) acc)))))
    '() (split body #\;)))

(define (join layer name) (if (string=? layer "") name (string-append layer "." name)))

(define (rules css)
  (let walk ([s (without-comments css)] [layer ""])
    (let loop ([i 0] [acc '()])
      (let ([open (search s "{" i)])
        (if (not open)
            (reverse acc)
            (let* ([end (closing s open)]
                   [start (let back ([k open]) (if (or (= k i) (memv (string-ref s (- k 1)) '(#\; #\}))) k (back (- k 1))))]
                   [prelude (trim (substring s start open))]
                   [body (substring s (+ open 1) end)])
              (loop (+ end 1)
                    (cond
                      [(prefix? "@layer " prelude)
                       (append (reverse (walk body (join layer (trim (substring prelude 7 (string-length prelude)))))) acc)]
                      [(prefix? "@keyframes" prelude) acc]
                      [(prefix? "@font-face" prelude) (cons (make-rule layer prelude (declarations-of body)) acc)]
                      [(prefix? "@" prelude) (append (reverse (walk body (string-append layer " " prelude))) acc)]
                      [else (cons (make-rule layer prelude (declarations-of body)) acc)]))))))))

(define (file-rules name) (rules (file-text name)))

(define (declaration rule property)
  (let ([d (assoc property (rule-declarations rule))]) (and d (cdr d))))

(define (statements css)
  (let ([s (without-comments css)])
    (map trim (filter (lambda (x) (not (string=? (trim x) ""))) (split (substring s 0 (or (search s "{" 0) (string-length s))) #\;)))))

(define (keyframe-names css)
  (let loop ([from 0] [acc '()])
    (let ([i (search css "@keyframes " from)])
      (if i
          (let ([name-start (+ i 11)])
            (loop name-start (cons (trim (substring css name-start (search css "{" name-start))) acc)))
          (reverse acc)))))

(define (var-chain value)
  (if (prefix? "var(--" value)
      (let ([comma (search value "," 0)])
        (if comma
            (cons (substring value 4 comma) (var-chain (trim (substring value (+ comma 1) (- (string-length value) 1)))))
            (list (substring value 4 (- (string-length value) 1)))))
      (list value)))

(define (references value)
  (let loop ([from 0] [acc '()])
    (let ([i (search value "var(--" from)])
      (if i
          (let ([end (let find ([k (+ i 4)]) (if (memv (string-ref value k) '(#\, #\))) k (find (+ k 1))))])
            (loop end (cons (cons (substring value (+ i 4) end) (char=? (string-ref value end) #\,)) acc)))
          (reverse acc)))))
