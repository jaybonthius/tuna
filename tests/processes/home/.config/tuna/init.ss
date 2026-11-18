(import (tuna) (tuna plugins) (tuna eval) (processes) (buffers) (document))

(putenv "PATH" (string-append (getenv "HOME") "/bin:" (getenv "PATH")))

(define log '())
(define (note! x) (set! log (cons x log)))
(define (taken!)
  (let ([l (reverse log)])
    (set! log '())
    l))

;; The log, with each run of output pieces joined, since a program's
;; writes may arrive in one read or several.
(define (joined!)
  (let loop ([l (taken!)] [acc '()])
    (cond
      [(null? l) (reverse acc)]
      [(and (pair? (car l)) (string? (caar l)) (pair? acc) (pair? (car acc)) (string? (caar acc)))
       (loop (cdr l) (cons (list (string-append (caar acc) (caar l)) (cadar l)) (cdr acc)))]
      [else (loop (cdr l) (cons (car l) acc))])))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (noting-output bytes end)
  (note! (if (eof-object? bytes) (list 'eof end) (list (utf8->string bytes) end))))
(define (noting-exit status) (note! (list 'exit status)))

(define (exited?) (and (pair? log) (pair? (car log)) (eq? (caar log) 'exit)))
(define (library-file name) (string-append (getenv "TUNA_LIBRARY") "/" name))
(define (user-file name) (string-append (getenv "HOME") "/.config/tuna/lib/" name))

(define (pi-lines)
  (let loop ([lines (let split ([text (document:text (buffers:document (buffers:find "*pi*")))] [acc '()])
                      (let find ([i 0])
                        (cond
                          [(= i (string-length text)) (reverse acc)]
                          [(char=? (string-ref text i) #\newline)
                           (split (substring text (+ i 1) (string-length text)) (cons (substring text 0 i) acc))]
                          [else (find (+ i 1))])))]
             [numbers '()])
    (cond
      [(null? lines) (reverse numbers)]
      [(and (> (string-length (car lines)) 5) (string=? (substring (car lines) 0 5) "line "))
       (loop (cdr lines) (cons (string->number (substring (car lines) 5 (string-length (car lines)))) numbers))]
      [else (loop (cdr lines) numbers)])))

(define (transcript-has? line)
  (let ([text (document:text (buffers:document (buffers:find "*pi*")))] [n (string-length line)])
    (let search ([i 0])
      (and (<= (+ i n) (string-length text))
           (or (string=? (substring text i (+ i n)) line) (search (+ i 1)))))))

(define (consecutive? numbers)
  (let loop ([numbers numbers] [next 1])
    (or (null? numbers) (and (= (car numbers) next) (loop (cdr numbers) (+ next 1))))))

(define (lines-past? n) (let ([numbers (pi-lines)]) (and (pair? numbers) (> (car (reverse numbers)) n))))
(import (console))
