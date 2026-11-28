#!tuna
(import (sampler-test))

(define (fixture name)
  (string-append (path-parent (car (command-line))) "/plugins/machine/tests/lib/machine-test/fixtures/" name))

(define (replace-line text prefix line)
  (let loop ([lines (split-lines text)] [acc '()])
    (cond
      [(null? lines) (apply string-append (map (lambda (l) (string-append l "\n")) (reverse acc)))]
      [(and (>= (string-length (car lines)) (string-length prefix))
            (string=? prefix (substring (car lines) 0 (string-length prefix))))
       (loop (cdr lines) (if line (cons line acc) acc))]
      [else (loop (cdr lines) (cons (car lines) acc))])))

(define (split-lines text)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length text)) (reverse (if (> i start) (cons (substring text start i) acc) acc))]
      [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring text start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (words line)
  (let loop ([chars (string->list line)] [word '()] [acc '()])
    (define (with-word) (if (null? word) acc (cons (list->string (reverse word)) acc)))
    (cond
      [(null? chars) (reverse (with-word))]
      [(char-whitespace? (car chars)) (loop (cdr chars) '() (with-word))]
      [else (loop (cdr chars) (cons (car chars) word) acc)])))

(define (pair-of source link a b)
  (sampler-test:point! link a)
  (sampler-test:wanting source 3600
    (lambda ()
      (sampler-test:point! link b)
      (sampler-test:reading! source))))
