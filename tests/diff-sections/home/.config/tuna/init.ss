(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin ui)
(use-plugin layout)
(use-plugin diff-sections)
(import (diff) (buffers) (views) (keys) (modes))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (view) (layout:selected-view))

(define (html v) (html->string (views:draw v client)))

(define (text b) (document:text (buffers:document b)))

(define (parse . parts)
  (let-values ([(out done) (open-bytevector-output-port)])
    (for-each (lambda (p) (if (string? p) (put-bytevector out (string->utf8 p)) (put-u8 out p))) parts)
    (diff:parse (done))))

(define (raw-bytes b)
  (let loop ([d (document:datums (buffers:document b))])
    (cond
      [(and (vector? d) (eq? (vector-ref d 0) 'document:raw-byte)) (list d)]
      [(pair? d) (append (loop (car d)) (loop (cdr d)))]
      [else '()])))

(buffers:define-kind diffs (content nodes))

(define (show-sections! name . sections)
  (let ([b (buffers:make name (apply diffs '() sections))])
    (buffers:set-silent! b #t)
    (modes:set-major-mode ui:section-mode b)
    (views:set-buffer! (view) b)
    (views:set-point! (view) 1)
    b))

(define (occurrences s part)
  (let loop ([i 0] [n 0])
    (cond
      [(> (+ i (string-length part)) (string-length s)) n]
      [(string=? (substring s i (+ i (string-length part))) part) (loop (+ i 1) (+ n 1))]
      [else (loop (+ i 1) n)])))

(define (line-position b line)
  (let* ([doc (buffers:document b)] [n (document:length doc)])
    (let loop ([p 0] [start #f] [chars '()])
      (cond
        [(= p n) #f]
        [(char? (document:token doc p))
         (let ([c (document:token doc p)])
           (cond
             [(char=? c #\newline)
              (if (and start (string=? (list->string (reverse chars)) line)) start (loop (+ p 1) #f '()))]
             [else (loop (+ p 1) (or start p) (cons c chars))]))]
        [else (loop (+ p 1) start chars)]))))
(import (console))
