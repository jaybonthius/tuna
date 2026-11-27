#!tuna
(import (buffers) (document) (views) (files) (syntax) (hooks) (xref))

(define code (string-append (getenv "HOME") "/code"))

(define (path name) (string-append code "/" name))

(define (%write! name text)
  (let ([file (path name)])
    (when (file-exists? file) (delete-file file))
    (call-with-output-file file (lambda (p) (put-string p text)))))

(define (%lines file)
  (let ([text (call-with-input-file file get-string-all)])
    (let loop ([i 0] [start 0] [n 1] [acc '()])
      (cond
        [(= i (string-length text)) (reverse acc)]
        [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ i 1) (+ n 1) (cons (cons n (substring text start i)) acc))]
        [else (loop (+ i 1) start n acc)]))))

(define (%contains? s part)
  (let loop ([i 0])
    (and (<= (+ i (string-length part)) (string-length s))
         (or (string=? (substring s i (+ i (string-length part))) part) (loop (+ i 1))))))

(define (%items-where keep)
  (apply append
    (map (lambda (file)
           (fold-right (lambda (l acc) (if (keep (cdr l)) (cons (xref:make-item (cdr l) file (car l) 0) acc) acc))
                       '() (%lines file)))
         (map path '("defs.txt" "sub/twice.txt" "uses.txt")))))

(define backend
  (xref:backend "words"
    [identifier-at-point
     (lambda (v)
       (let-values ([(s e) (syntax:symbol-bounds (views:buffer v) (views:point v))])
         (and s (< s e) (document:text (buffers:document (views:buffer v)) s e))))]
    [identifiers (lambda (input) (filter (lambda (n) (%contains? n input)) '("total" "average" "tally")))]
    [definitions (lambda (name) (%items-where (lambda (line) (string=? line (string-append "def " name)))))]
    [references (lambda (name) (%items-where (lambda (line) (and (%contains? line name) (not (%contains? line "def "))))))]
    [apropos (lambda (pattern) (%items-where (lambda (line) (and (%contains? line "def ") (%contains? line pattern)))))]))

(define (%code-backend view) backend)

(for-each (lambda (folder) (unless (file-exists? folder) (mkdir folder))) (list code (path "sub")))
(%write! "defs.txt" "def total\ndef average\ndef tally\n")
(%write! "uses.txt" "x = total\ny = average + total\n")
(%write! "sub/twice.txt" "note\ndef total\n")

(hooks:add! files:after-visit
  (lambda (b)
    (when (%contains? (or (files:path b) "") "/code/")
      (buffers:with-buffer b (hooks:add-local! xref:backends %code-backend)))))
