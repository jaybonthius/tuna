(import (tuna) (test) (test-runner) (tables) (buffers) (document) (syntax-highlighting) (outline) (chez-scheme)
        (chez-scheme-test scheme-buffers))

(define (offset text word)
  (let ([n (string-length word)])
    (let loop ([i 0])
      (if (string=? (substring text i (+ i n)) word) i (loop (+ i 1))))))

;; A file buffer's text starts one position in.
(define (entries o)
  (let ([found '()])
    (outline:walk o
      (lambda (e ancestors)
        (set! found (cons (list (length ancestors) (outline:entry-name e) (outline:entry-kind e)
                                (- (outline:entry-start e) 1) (- (outline:entry-end e) 1) (- (outline:entry-point e) 1))
                          found))))
    (reverse found)))

(define (answered b)
  (test-runner:wait-until (lambda () (chez-scheme:outline-source b)))
  (outline:get b))

(define src-text
  (string-append "(define (alpha x) x)\n(define beta 2)\n(define-record-type point (fields x y))\n"
                 "(define-syntax swap! (syntax-rules ()))\n(let loop ((i 0)) i)\n  (define (indented y) y)\n"
                 "(define (omega) 1)\n"))

(define (line-range text start-word)
  (let* ([line (let loop ([i (offset text start-word)]) (if (or (= i 0) (char=? (string-ref text (- i 1)) #\newline)) i (loop (- i 1))))]
         [start (let loop ([i line]) (if (char=? (string-ref text i) #\() i (loop (+ i 1))))]
         [end (let loop ([i start]) (if (char=? (string-ref text i) #\newline) i (loop (+ i 1))))])
    (list start end)))

(define (expected text name kind)
  (append (list 0 name kind) (line-range text name) (list (offset text name))))

(test "the source gives each top-level definition the highlighting job found, in buffer order, its kind from its form and its point on its name; a named let is none"
  (let ([b (chez-scheme-test/scheme-buffers:scheme-buffer "src.scm" src-text)])
    (check-equal? (list (expected src-text "alpha" 'function) (expected src-text "beta" 'variable)
                        (expected src-text "point" 'struct) (expected src-text "swap!" 'macro)
                        (expected src-text "indented" 'function) (expected src-text "omega" 'function))
                  (entries (answered b)))))

(define tuna-text
  "(options:define-option x 1 fixnum?)\n(hooks:define-hook h)\n(commands:define-command (c) \"d\" 1)\n(use-plugin lsp)\n(defparser q 1)\n(define f (lambda (y) y))\n(define-values (v w) (values 1 2))\n")

(test "Tuna's defining forms have their kinds, use-plugin lists its plugin, and a form a user adds to outline-kinds is listed"
  (let ([b (chez-scheme-test/scheme-buffers:scheme-buffer "init.ss" tuna-text)])
    (check-equal? '(("x" variable) ("h" event) ("c" function) ("lsp" package) ("f" function) ("v" variable))
                  (map (lambda (e) (list (cadr e) (caddr e))) (entries (answered b))))
    (tables:set! chez-scheme:outline-kinds 'defparser 'function)
    (syntax-highlighting:update! b)
    (test-runner:wait-until
      (lambda () (equal? '("x" "h" "c" "lsp" "q" "f" "v") (map outline:entry-name (outline:roots (outline:get b))))))
    (tables:remove! chez-scheme:outline-kinds 'defparser)))

(test "before the highlighting job answers the source gives #f; its answer forgets the outline, so the next get gives it"
  (let ([b (chez-scheme-test/scheme-buffers:scheme-buffer "late.scm" "(define (late) 1)\n")])
    (check-equal? #f (chez-scheme:outline-source b))
    (check-equal? #f (outline:get b))
    (test-runner:wait-until (lambda () (outline:get b)))
    (check-equal? '("late") (map outline:entry-name (outline:roots (outline:get b))))))

(test "a definition inside a body, or in a comment or a string, is no entry"
  (let ([b (chez-scheme-test/scheme-buffers:scheme-buffer "body.scm"
             "(define (f) (define inner 1) inner)\n;; (define x 1)\n#;(define z 3)\n(display \"(define y 2)\")\n")])
    (check-equal? '("f") (map outline:entry-name (outline:roots (answered b))))))

(define library-text
  "(library (my lib)\n  (export a b)\n  (import (rnrs))\n  (define a 1)\n  (define (b) 2))\n(module (c) (define c 3))\n(module named (d) (define d 4))\n")

(test "a library form is a module entry named as written, holding its definitions; an anonymous module's definitions stand in its place, a named one's under it"
  (let* ([b (chez-scheme-test/scheme-buffers:scheme-buffer "lib.sls" library-text)] [found (entries (answered b))])
    (check-equal? '((0 "(my lib)" module) (1 "a" variable) (1 "b" function) (0 "c" variable) (0 "named" module)
                    (1 "d" variable))
                  (map (lambda (e) (list-head e 3)) found))
    (check-equal? (list 0 (string-length "(library (my lib)\n  (export a b)\n  (import (rnrs))\n  (define a 1)\n  (define (b) 2))")
                        (offset library-text "(my lib)"))
                  (cdddr (car found)))))

(test "a definition left open, as while it is typed, runs to the end of the text"
  (let* ([text "(define (done) 1)\n(define (open x)\n  (car x"]
         [b (chez-scheme-test/scheme-buffers:scheme-buffer "open.scm" text)])
    (check-equal? (list (list 0 "done" 'function 0 17 9) (list 0 "open" 'function 18 (string-length text) 27))
                  (entries (answered b)))))
