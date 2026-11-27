(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (buffers) (document) (views) (layout) (files)
        (chez-scheme) (lsp) (servers) (installed))

(installed:require-programs! '("czlsp"))

(options:set! lsp:send-changes-delay 0.05)

(lsp:define-server czlsp '("czlsp" "--stdio"))

(tables:set! lsp:language-servers "scheme" (list czlsp))

(hooks:add! chez-scheme:mode-hook lsp:ensure)

(define code (string-append servers:home "/code"))

(servers:write-file! (string-append code "/.git/HEAD") "")

(servers:write-file! (string-append code "/f.ss") "(define (f x)\n")

(define f (servers:visit! (string-append code "/f.ss")))

(define (around)
  (let ([doc (buffers:document f)] [p (views:point (servers:view))])
    (list (document:text doc 0 p) (document:text doc p (document:length doc)))))

(test-runner:wait-until
  (lambda () (let ([cs (lsp:buffer-connections f)]) (and (pair? cs) (lsp:connection-capability (car cs) "documentFormattingProvider")))))

(test "RET indents a Scheme buffer in its own command and asks czlsp nothing; czlsp formats the buffer on request"
  (views:set-point! (servers:view) (+ 1 (string-length "(define (f x)")))
  (test-user:press! "RET")
  (check-equal? '("(define (f x)\n  " "\n") (around))
  (test-user:type! "(+ x 1))")
  (views:set-point! (servers:view) (+ 1 (string-length "(define (f x)\n  (+ x")))
  (test-user:press! "RET")
  (check-equal? '("(define (f x)\n  (+ x\n     " "1))\n") (around))
  (buffers:replace! f 1 (- (document:length (buffers:document f)) 1) "(define (g y)\n(+ y 2))\n")
  (views:call-with-view (servers:view) (lambda () (lsp:format-buffer f)))
  (test-runner:wait-until (lambda () (string=? "(define (g y)\n  (+ y 2))\n" (servers:text f)))))

(test "turned on, on-type formatting asks nothing for a RET whose command went on to indent the line"
  (options:set! lsp:on-type-formatting? #t)
  (views:set-point! (servers:view) (+ 1 (string-length "(define (g y)")))
  (test-user:press! "RET")
  (check-equal? '("(define (g y)\n  " "\n  (+ y 2))\n") (around))
  (lsp:shutdown-all))
