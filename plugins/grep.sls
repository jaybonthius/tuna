#!tuna
(import (completion) (buffers) (commands) (document) (files) (jobs) (keys) (layout) (views))

(define-option min-input 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters the search must hold before grep:grep starts a job.")

(define-option delay 0.2 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds without typing before grep:grep starts a job.")

(define-option max-file-size 1000000 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "The largest file, in bytes, that grep:grep reads.")

(jobs:define-worker (%grep options emit receive)
  (import (completion matcher))
  (let ([root (vector-ref options 0)] [minimum (vector-ref options 1)] [delay (vector-ref options 2)]
        [max-size (vector-ref options 3)])
    (define (search-of prefix)
      (let ([n (string-length prefix)])
        (if (and (fx> n 0) (char=? (string-ref prefix (fx- n 1)) #\#)) (substring prefix 0 (fx- n 1)) prefix)))
    (define (components s)
      (let loop ([cs (string->list s)] [current '()] [acc '()])
        (define (finish) (if (null? current) acc (cons (list->string (reverse current)) acc)))
        (cond
          [(null? cs) (reverse (finish))]
          [(and (char=? (car cs) #\\) (pair? (cdr cs)) (char=? (cadr cs) #\space))
           (loop (cddr cs) (cons #\space current) acc)]
          [(char=? (car cs) #\space) (loop (cdr cs) '() (finish))]
          [else (loop (cdr cs) (cons (car cs) current) acc)])))
    (define (binary? bv)
      (let ([n (fxmin 8192 (bytevector-length bv))])
        (let loop ([i 0]) (and (fx< i n) (or (fx= (bytevector-u8-ref bv i) 0) (loop (fx+ i 1)))))))
    (define (read-text path)
      (guard (c [#t #f])
        (let ([p (open-file-input-port path)])
          (dynamic-wind
            void
            (lambda ()
              (and (<= (port-length p) max-size)
                   (let ([bv (get-bytevector-all p)])
                     (cond
                       [(eof-object? bv) ""]
                       [(binary? bv) #f]
                       [else (utf8->string bv)]))))
            (lambda () (close-port p))))))
    (define (lines-of text)
      (let loop ([i 0] [start 0] [acc '()])
        (cond
          [(fx= i (string-length text))
           (reverse (if (fx< start i) (cons (substring text start i) acc) acc))]
          [(char=? (string-ref text i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (substring text start i) acc))]
          [else (loop (fx+ i 1) start acc)])))
    (define (walk! matches?)
      (call/cc
        (lambda (k)
          (let visit ([dir root] [shown ""])
            (for-each
              (lambda (name)
                (unless (char=? (string-ref name 0) #\.)
                  (let ([path (string-append dir "/" name)] [rel (string-append shown name)])
                    (let ([newer (receive 0)])
                      (unless (eof-object? newer) (k newer)))
                    (cond
                      [(guard (c [#t #t]) (file-symbolic-link? path)) (void)]
                      [(guard (c [#t #f]) (file-directory? path)) (visit path (string-append rel "/"))]
                      [else
                       (let ([text (read-text path)])
                         (when text
                           (let loop ([lines (lines-of text)] [n 1] [found '()])
                             (cond
                               [(null? lines) (unless (null? found) (emit (list->vector (reverse found))))]
                               [(matches? (car lines))
                                (loop (cdr lines) (fx+ n 1)
                                      (cons (cons (string-append rel ":" (number->string n) ":" (car lines))
                                                  (cons path n))
                                            found))]
                               [else (loop (cdr lines) (fx+ n 1) found)]))))]))))
              (guard (c [#t '()]) (list-sort string<? (directory-list dir)))))
          #f)))
    (define (settle prefix)
      (let ([next (receive delay)])
        (if (eof-object? next) prefix (settle next))))
    (let loop ([prefix (receive)] [last-search #f])
      (let* ([prefix (settle prefix)] [search (search-of prefix)])
        (if (equal? search last-search)
            (loop (receive) search)
            (begin
              (emit 'clear)
              (let ([newer (and (fx>= (string-length search) minimum)
                                (let ([terms (map (lambda (c) (list 'contains c)) (components search))])
                                  (and (pair? terms) (walk! (pattern-matcher terms)))))])
                (if newer (loop newer #f) (loop (receive) search)))))))))

(define (%grep-split input)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length input)) i]
      [(char=? (string-ref input i) #\#) (fx+ i 1)]
      [else (loop (fx+ i 1))])))

(define (%home) (or (getenv "HOME") "/"))

(define (%after-last-slash input)
  (let loop ([i (string-length input)])
    (cond
      [(fx= i 0) 0]
      [(char=? (string-ref input (fx- i 1)) #\/) i]
      [else (loop (fx- i 1))])))

(define (%default-directory)
  (let* ([v (views:current)] [b (and v (views:buffer v))] [path (and b (files:path b))])
    (if path
        (substring path 0 (%after-last-slash path))
        (string-append (%home) "/"))))

(define (%grep-root)
  (let ([dir (%default-directory)])
    (if (and (fx> (string-length dir) 1) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
        (substring dir 0 (fx- (string-length dir) 1))
        dir)))

(define (%read-location)
  (completion:read "Grep: "
    (list (completion:source
            (job %grep (vector (%grep-root) (min-input) (delay) (max-file-size)))
            (split %grep-split)
            (category completion:location-category)))))

(commands:define-command (grep [location (%read-location)])
  "Visits LOCATION, a line read from the files under the current buffer's directory."
  (let ([b (files:visit (car location))])
    (layout:switch-to-buffer b)
    (let ([doc (buffers:document b)])
      (views:set-point! (views:current)
        (document:line-start doc (fxmax 1 (fxmin (cdr location) (document:line doc (fx- (document:length doc) 1)))))))))

(keys:bind! keys:global "M-s g" grep)
