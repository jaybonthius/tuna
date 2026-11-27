#!tuna
(import (diff) (ui) (buffers) (document) (views) (layout) (modes) (test-user))

(define (parse . parts)
  (let-values ([(out done) (open-bytevector-output-port)])
    (for-each (lambda (p) (if (string? p) (put-bytevector out (string->utf8 p)) (put-u8 out p))) parts)
    (diff:parse (done))))

(buffers:define-kind diffs (content nodes))

(define (view) (layout:selected-view))

(define (show! . sections)
  (let ([b (buffers:make (buffers:free-name "*diff*") (apply diffs '() sections))])
    (buffers:set-silent! b #t)
    (modes:set-major-mode ui:section-mode b)
    (views:set-buffer! (view) b)
    (views:set-point! (view) 1)
    b))

(define (text b) (document:text (buffers:document b)))

(define (line-position b line)
  (let* ([doc (buffers:document b)] [n (document:length doc)])
    (let loop ([p 0] [start #f] [chars '()])
      (cond
        [(= p n) (error 'diff-sections-test:line-position "no such line" line)]
        [(char? (document:token doc p))
         (let ([c (document:token doc p)])
           (cond
             [(not (char=? c #\newline)) (loop (+ p 1) (or start p) (cons c chars))]
             [(and start (string=? line (list->string (reverse chars)))) start]
             [else (loop (+ p 1) #f '())]))]
        [else (loop (+ p 1) start chars)]))))

(define (raw-bytes b)
  (let loop ([d (document:datums (buffers:document b))])
    (cond
      [(and (vector? d) (eq? (vector-ref d 0) 'document:raw-byte)) (list (cdr (assq 'byte (vector-ref d 1))))]
      [(pair? d) (append (loop (car d)) (loop (cdr d)))]
      [else '()])))

(define (drawn class)
  (test-user:settle)
  (let ([id (number->string (views:id (view)))])
    (test-user:elements
      (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
            (test-user:elements-with (test-user:screen) "data-view"))
      class)))
