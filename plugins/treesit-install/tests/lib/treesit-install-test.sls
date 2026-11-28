#!tuna
(import (test-runner) (test-user) (options) (buffers) (modes) (ask) (processes) (treesit-test))

(define home (getenv "HOME"))

;; No test fetches over the network: a grammar's source is a local
;; repository, the copy of tree-sitter-python chez-treesitter vendors.
(define vendored
  (string-append (path-parent (car (command-line))) "/libraries/chez-treesitter/vendor/tree-sitter-python"))

(define pinned "293fdc02038ee2bf0e2e206711b69c90ac0d413f")

(define (run! program . arguments)
  (let-values ([(status output errors) (processes:run program arguments)])
    (unless (eqv? status 0) (errorf 'treesit-install-test:run! "~a ~s: ~a" program arguments (utf8->string errors)))
    (let ([text (utf8->string output)])
      (if (and (fx> (string-length text) 0) (char=? (string-ref text (fx- (string-length text) 1)) #\newline))
          (substring text 0 (fx- (string-length text) 1))
          text))))

(define (repository! name files)
  (let ([folder (string-append home "/" name)])
    (mkdir folder)
    (run! "git" "-C" folder "init" "-q")
    (for-each (lambda (file) (treesit-test:write-file! (string-append folder "/" (car file)) (cdr file))) files)
    (run! "git" "-C" folder "add" ".")
    (run! "git" "-C" folder "-c" "user.name=t" "-c" "user.email=t@t" "commit" "-q" "-m" "one")
    (values folder (run! "git" "-C" folder "rev-parse" "HEAD"))))

(define (path-of! name programs)
  (let ([folder (string-append home "/" name)])
    (mkdir folder)
    (for-each (lambda (program) (run! "ln" "-s" (processes:program-path program) (string-append folder "/" program)))
              programs)
    folder))

(define %asked (quote ()))
(define %told (quote ()))
(define %answer #t)

(define (answer! v) (set! %answer v))


(define (take-asked!) (let ([a %asked]) (set! %asked '()) a))

(define (asked?) (pair? %asked))

;; runs tells each run's end too, which is not this plugin's to test.
(define (take-told!)
  (let ([t %told])
    (set! %told '())
    (filter (lambda (text) (not (and (fx> (string-length text) 17) (string=? "*treesit-install " (substring text 0 17)))))
            t)))

(define (wait-told text) (test-runner:wait-until (lambda () (member text %told))))

(define (buffer-in mode)
  (let ([b (buffers:make (buffers:free-name "b") "def f(x):\n    return x\n")])
    (modes:set-major-mode mode b)
    b))

(define coloured '(("def" keyword.function) ("f" function) ("x" variable.parameter) ("return" keyword.return)))

(options:set! ask:y-or-n-reader (lambda (question) (set! %asked (append %asked (list question))) %answer))
(options:set! ask:message-writer (lambda (text) (set! %told (append %told (list text)))))
