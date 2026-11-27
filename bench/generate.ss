;; Sizes follow a real Emacs configuration's packages: about 240 lines and
;; 28 top-level definitions per file.

(define home (car (command-line-arguments)))
(define shape (string->symbol (cadr (command-line-arguments))))
(define plugins 100)
(define extras 50)
(define helpers 22)
(define commands 6)

;; A fixed linear congruential generator, so every run writes the same home.
(define seed 7)
(define (random-below n)
  (set! seed (mod (+ (* seed 1103515245) 12345) 2147483648))
  (mod (quotient seed 65536) n))

(define (plugin-id i) (format "p~3,'0d" i))

(define (ensure-directory path)
  (unless (file-directory? path)
    (ensure-directory (path-parent path))
    (mkdir path)))

(define (write-lines path lines)
  (ensure-directory (path-parent path))
  (call-with-output-file path
    (lambda (p) (for-each (lambda (line) (put-string p line) (newline p)) lines))
    'replace))

(define (helper k indent)
  (map (lambda (line) (string-append indent line))
       (list
         (format "(define (h~a xs n)" k)
         "  (let loop ([xs xs] [i 0] [acc '()])"
         "    (cond"
         "      [(null? xs) (reverse acc)]"
         "      [(> i n) (append (reverse acc) xs)]"
         "      [(string? (car xs))"
         (format "       (loop (cdr xs) (+ i 1) (cons (string-append (car xs) \"-~a\") acc))]" k)
         (format "      [(number? (car xs)) (loop (cdr xs) (+ i 1) (cons (* (car xs) ~a) acc))]" (+ k 1))
         (format "      [else (loop (cdr xs) (+ i 1) (cons ~a acc))])))"
           (if (> k 0) (format "(h~a (list (car xs)) 1)" (- k 1)) "(list (car xs))")))))

(define (helpers-of count)
  (if (eq? shape 'few)
      (append
        (list (format "(module (~{h~a~^ ~})" (iota count)))
        (apply append (map (lambda (k) (helper k "  ")) (iota count)))
        (list ")"))
      (apply append (map (lambda (k) (helper k "")) (iota count)))))

(define (command k dependencies)
  (list
    (format "(define (cmd~a arg)" k)
    (format "  \"Runs step ~a.\"" k)
    (format "  (let ([e (make-entry '~a ~a)])" k
      (if (null? dependencies)
          "arg"
          (format "(~a:cmd~a arg)" (list-ref dependencies (mod k (length dependencies))) (mod k commands))))
    "    (when (enabled)"
    (format "      (entry-value-set! e (h~a (list arg \"x\" 3) (width))))" (mod k helpers))
    "    (after-run (entry-value e))"
    "    (entry-value e)))"))

(define (main-module i)
  (let* ([dependencies
          (if (= i 0)
              '()
              (let loop ([n (random-below 4)] [picked '()])
                (if (= n 0)
                    (sort string<? picked)
                    (let ([d (plugin-id (random-below i))])
                      (loop (- n 1) (if (member d picked) picked (cons d picked)))))))]
         [imports (append '("(options)" "(hooks)")
                          (map (lambda (d) (format "(~a)" d)) dependencies)
                          (if (< i extras) (list (format "(~a extra)" (plugin-id i))) '()))])
    (append
      (list "#!tuna")
      (list (format "(import ~{~a~^ ~})" imports))
      (list
        "(options:define-option width 70 fixnum? \"Width of the output.\")"
        "(options:define-option enabled #t boolean? \"Whether the plugin acts.\")"
        "(hooks:define-hook after-run \"Called with each result.\")"
        "(define-record-type entry (fields key (mutable value)))"
        "(define-syntax with-entry"
        "  (syntax-rules () [(_ (k v) body ...) (let ([e (make-entry k v)]) body ...)]))")
      (helpers-of helpers)
      (apply append (map (lambda (k) (command k dependencies)) (iota commands)))
      (if (null? dependencies)
          '()
          (list
            "(define (on-dependency-run v) (h0 (list v) 1))"
            (format "(hooks:add! ~a:after-run on-dependency-run)" (car dependencies)))))))

(define (extra-module)
  (append
    (list
      "#!tuna"
      "(import (options) (hooks))"
      "(define-record-type entry (fields key (mutable value)))"
      "(options:define-option enabled #t boolean? \"Whether the extra acts.\")"
      "(hooks:define-hook after-run \"Called with each result.\")"
      "(define (width) 60)")
    (helpers-of 10)
    (apply append (map (lambda (k) (command k '())) (iota commands)))))

(define plugins-root (string-append home "/.local/share/tuna/plugins"))

(for-each
  (lambda (i)
    (let ([id (plugin-id i)])
      (write-lines (format "~a/~a/~a.sls" plugins-root id id) (main-module i))
      (when (< i extras)
        (write-lines (format "~a/~a/~a/extra.sls" plugins-root id id) (extra-module)))))
  (iota plugins))

(write-lines (string-append home "/.config/tuna/init.ss")
  (append
    (list "(import (tuna) (options))")
    (map (lambda (i) (format "(import (~a))" (plugin-id i))) (iota plugins))
    (list
      "(options:set! p010:width 80 p020:enabled #f)"
      "(printf \"configured-ms ~a check ~s\\n\" (real-time) (p000:cmd0 \"x\"))"
      "(exit)")))
