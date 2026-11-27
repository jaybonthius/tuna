#!tuna
(import (document) (treesit highlight))

(define (%install) (path-parent (car (command-line))))

(define shipped-folders
  (list (string-append (%install) "/plugins/python/src/python/queries")
        (string-append (%install) "/plugins/treesit/src/treesit/nvim-treesitter/runtime/queries")))

(define (shipped) (query-files shipped-folders "python" "highlights"))

(define %queries 0)

(define (query! text)
  (set! %queries (+ %queries 1))
  (let ([folder (format "~a/queries-~a/python" (getenv "HOME") %queries)])
    (mkdir (path-parent folder))
    (mkdir folder)
    (let ([file (string-append folder "/highlights.scm")])
      (call-with-output-file file (lambda (p) (put-string p text)))
      file)))

(define-record-type %session
  (sealed #t)
  (fields grammar highlight (mutable doc) files (mutable excluded) (mutable drawn) (mutable since) (mutable faces)
          (mutable data)))

(define (%open grammar text files excluded drawn)
  (make-%session grammar (make-highlight) (document:from-utf8 (string->utf8 text)) files excluded drawn '()
                 (make-vector (string-length text) #f) #f))

(define open
  (case-lambda
    [(grammar text files excluded) (%open grammar text files excluded '())]
    [(grammar text files excluded drawn) (%open grammar text files excluded drawn)]))

;; A job's input gives each query file with its modification time; a
;; session never rewrites a file, so it gives none.
(define (%input s)
  (list (%session-grammar s) "python" (map (lambda (file) (cons file #f)) (%session-files s))
        (%session-excluded s) (%session-drawn s)))

(define (%paint! s answer)
  (let ([v (%session-faces s)])
    (if (vector? answer)
        (vector-fill! v #f)
        (begin
          (do ([i (car answer) (+ i 1)]) ((= i (cadr answer))) (vector-set! v i #f))
          (vector-for-each
            (lambda (span)
              (let ([face (cdr (assq 'face (caddr span)))])
                (do ([i (car span) (+ i 1)]) ((= i (cadr span))) (vector-set! v i face))))
            (caddr answer))))))

(define (step! s)
  (let ([since (reverse (%session-since s))])
    (%session-since-set! s '())
    (call-with-values (lambda () ((%session-highlight s) (%session-doc s) (%input s) since))
      (case-lambda
        [(layers data) (%session-data-set! s data) (%paint! s (car layers)) (values #f #f)]
        [(layers data more)
         (%session-data-set! s data)
         (let ([answer (car layers)])
           (%paint! s answer)
           (values (and (not (vector? answer)) (< (car answer) (cadr answer)) (list (car answer) (cadr answer)))
                   more))]))))

(define (settle! s)
  (let loop ([ranges '()])
    (let-values ([(range more) (step! s)])
      (let ([ranges (if range (cons range ranges) ranges)])
        (if more (loop ranges) (reverse ranges))))))

(define (text s) (document:text (%session-doc s)))

(define (problems s) (or (%session-data s) '()))

(define (set-drawn! s drawn) (%session-drawn-set! s drawn))

(define (replace! s start end new)
  (let ([n (string-length new)] [v (%session-faces s)])
    (%session-doc-set! s (document:replace (%session-doc s) start end (document:from-utf8 (string->utf8 new))))
    (%session-since-set! s (cons (list start (- end start) n) (%session-since s)))
    (%session-faces-set! s
      (list->vector (append (list-head (vector->list v) start) (make-list n #f) (list-tail (vector->list v) end))))))

(define (faces s) (vector->list (%session-faces s)))

(define (faces-between s from to) (list-head (list-tail (faces s) from) (- to from)))

(define runs
  (case-lambda
    [(s) (runs s 0 (vector-length (%session-faces s)))]
    [(s from to)
     (let ([t (text s)] [v (%session-faces s)])
       (let loop ([i from] [acc '()])
         (if (>= i to)
             (reverse acc)
             (let ([face (vector-ref v i)])
               (let run ([j (+ i 1)])
                 (if (and (< j to) (equal? (vector-ref v j) face))
                     (run (+ j 1))
                     (loop j (if face (cons (list (substring t i j) face) acc) acc))))))))]))

(define (highlighted grammar text files excluded)
  (let ([s (open grammar text files excluded)])
    (settle! s)
    s))

(define (first-difference a b)
  (let ([va (%session-faces a)] [vb (%session-faces b)])
    (let loop ([i 0])
      (cond
        [(= i (vector-length va)) #f]
        [(equal? (vector-ref va i) (vector-ref vb i)) (loop (+ i 1))]
        [else (list i (vector-ref va i) (vector-ref vb i))]))))

(define (fresh-difference s)
  (first-difference s (highlighted (%session-grammar s) (text s) (%session-files s) (%session-excluded s))))
