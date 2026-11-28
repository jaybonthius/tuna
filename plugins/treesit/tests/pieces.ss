(import (tuna) (test) (tables) (options) (languages) (treesit) (python) (treesit highlight) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python python:python)
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (languages:grammar-commit python) grammar)

(define excluded (options:default treesit:excluded-captures))

(define (open text) (treesit-test/session:open grammar text (treesit-test/session:shipped) excluded))

(define settle! treesit-test/session:settle!)
(define step! treesit-test/session:step!)
(define replace! treesit-test/session:replace!)
(define text-of treesit-test/session:text)

(define (line-count text)
  (let loop ([i 0] [k 0])
    (if (= i (string-length text)) k (loop (+ i 1) (if (char=? (string-ref text i) #\newline) (+ k 1) k)))))

(define (line-start text line)
  (let loop ([i 0] [l 0])
    (cond
      [(= l line) i]
      [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ l 1))]
      [else (loop (+ i 1) l)])))

(define (overlap? a b) (and (< (car a) (cadr b)) (< (car b) (cadr a))))

(define (drawn-around s line)
  (cons (line-start (text-of s) (max 0 (- line 20)))
        (line-start (text-of s) (min (line-count (text-of s)) (+ line 40)))))

(define (edit-case s line typed)
  (let* ([at (line-start (text-of s) line)]
         [drawn (drawn-around s line)]
         [from (car drawn)]
         [to (+ (cdr drawn) (string-length typed))])
    (treesit-test/session:set-drawn! s (list (cons from to)))
    (replace! s at at typed)
    (let-values ([(first more) (step! s)])
      (let* ([rest (if more (settle! s) '())]
             [whole? (= (string-length (text-of s))
                        (fold-left (lambda (sum r) (+ sum (- (cadr r) (car r)))) 0 (cons first rest)))]
             [failed (filter cdr
                       (list
                         (cons 'first-inside-drawn (not (and first (<= from (car first)) (<= (cadr first) to))))
                         (cons 'first-whole-drawn (and whole? (not (equal? first (list from to)))))
                         (cons 'later-outside-first (exists (lambda (r) (overlap? r first)) rest))
                         (cons 'later-in-pieces (exists (lambda (r) (> (- (cadr r) (car r)) piece-size)) rest))
                         (cons 'fresh (treesit-test/session:fresh-difference s))))])
        (replace! s at (+ at (string-length typed)) "")
        (settle! s)
        (list whole? (map car failed))))))

(define (edit-cases s lines typed)
  (let ([results (map (lambda (line) (edit-case s line typed)) lines)])
    (list (length (filter car results)) (length results)
          (apply append (map (lambda (r line) (if (null? (cadr r)) '() (list (cons line (cadr r))))) results lines)))))

(define (spaced-lines text count)
  (let ([lines (line-count text)])
    (map (lambda (k) (quotient (* k lines) (+ count 1))) (cdr (iota (+ count 1))))))

(test "in 60 KB, a ( or a \"\"\" typed at the start of twelve lines, the lines around it drawn: the drawn range is coloured first and whole, the rest in pieces, ending as a highlight from nothing"
  (let* ([text (treesit-test:grown-text 60000)] [s (open text)])
    (check-equal? 4 (length (settle! s)))
    (check-equal? '(7 12 ()) (edit-cases s (spaced-lines text 12) "("))
    (check-equal? '(0 12 ()) (edit-cases s (spaced-lines text 12) "\"\"\""))))

(test "a newer edit, and a scroll, are taken between pieces: the newly drawn lines come next, with their colours, before the rest"
  (let* ([text (treesit-test:grown-text 60000)]
         [s (open text)]
         [lines (line-count text)])
    (settle! s)
    (let ([line (find (lambda (line) (car (edit-case s line "("))) (spaced-lines text 12))])
      (replace! s (line-start (text-of s) line) (line-start (text-of s) line) "(")
      (treesit-test/session:set-drawn! s (list (drawn-around s line)))
      (let-values ([(first more) (step! s)])
        (check-equal? (list (car (drawn-around s line)) (cdr (drawn-around s line))) first)
        (check more)
        (let-values ([(second more) (step! s)])
          (check-equal? #f (overlap? second first))
          (check more)))
      (let* ([far (if (< line (quotient lines 2)) (- lines 400) 400)])
        (replace! s (line-start (text-of s) far) (line-start (text-of s) far) "\"\"\"")
        (let ([d2 (drawn-around s far)])
          (treesit-test/session:set-drawn! s (list d2))
          (let-values ([(third more) (step! s)])
            (check-equal? (list (car d2) (cdr d2)) third)
            (check more))
          (let ([fresh (treesit-test/session:highlighted grammar (text-of s) (treesit-test/session:shipped) excluded)])
            (check-equal? (treesit-test/session:faces-between fresh (car d2) (cdr d2))
                          (treesit-test/session:faces-between s (car d2) (cdr d2)))
            (let ([d3 (drawn-around s (if (< line (quotient lines 2)) (- lines 150) 150))])
              (treesit-test/session:set-drawn! s (list d3))
              (let-values ([(fourth more) (step! s)])
                (check-equal? (list (car d3) (cdr d3)) fourth)
                (check more))
              (settle! s)
              (check-equal? #f (treesit-test/session:first-difference s fresh)))))))))

(test "in 230 KB, as in 60 KB"
  (let* ([text (treesit-test:grown-text 230000)] [s (open text)])
    (check-equal? 15 (length (settle! s)))
    (check-equal? '(7 12 ()) (edit-cases s (spaced-lines text 12) "("))
    (check-equal? '(0 12 ()) (edit-cases s (spaced-lines text 12) "\"\"\""))))

(test "in 1 MB, as in 60 KB, at line 11"
  (let* ([text (treesit-test:grown-text 1000000)] [s (open text)])
    (check-equal? 62 (length (settle! s)))
    (check-equal? '(1 1 ()) (edit-cases s '(11) "("))
    (check-equal? '(0 1 ()) (edit-cases s '(11) "\"\"\""))))
