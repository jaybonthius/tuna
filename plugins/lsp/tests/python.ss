(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (buffers) (document) (views) (layout)
        (files) (xref) (completion) (completion-list) (layout-float) (completion-popup) (diagnostics) (python) (lsp) (servers)
        (installed))

(installed:require-programs! '("basedpyright-langserver" "ruff"))

(options:set! lsp:send-changes-delay 0.05)

(tables:set! lsp:language-servers "python" (list lsp:basedpyright lsp:ruff))

(hooks:add! python:mode-hook lsp:ensure)

(define shop (string-append servers:home "/shop"))

(servers:write-file! (string-append shop "/.git/HEAD") "")
(servers:write-file! (string-append shop "/prices.py") "def total(items):\n    return sum(items)\n")
(servers:write-file! (string-append shop "/cart.py") "import os\nfrom prices import total\n\n\ndef checkout(items):\n    return total(items)\n")
(servers:write-file! (string-append shop "/main.py") "def run():\n    return tota\n")

(define cart (servers:visit! (string-append shop "/cart.py")))

(define (messages b)
  (map (lambda (d) (list (diagnostics:diagnostic-origin d) (diagnostics:diagnostic-code d) (diagnostics:diagnostic-message d)))
       (diagnostics:in b)))

(define (mentions-os? s)
  (exists (lambda (i) (string=? "\"os\"" (substring s i (+ i 4)))) (iota (max 0 (- (string-length s) 3)))))

(define (basedpyright-unused? m) (and (equal? (car m) "basedpyright") (mentions-os? (caddr m))))

(define (ruff-unused? m) (and (equal? (car m) "Ruff") (equal? (cadr m) "F401")))

(define (session) (views:call-with-view (servers:view) completion:current-session))

(define (texts)
  (let* ([s (session)] [ms (completion:session-matches s)])
    (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms)))))

(test "basedpyright and ruff each report the unused import"
  (test-runner:wait-until (lambda () (and (exists basedpyright-unused? (messages cart)) (exists ruff-unused? (messages cart)))))
  (check-equal? "`os` imported but unused" (caddr (find ruff-unused? (messages cart)))))

(test "M-. on a name imported from another file goes to its definition there"
  (views:set-point! (servers:view) (+ 1 (string-length "import os\nfrom prices import total\n\n\ndef checkout(items):\n    return ")))
  (servers:press-until-ended! "M-." xref:find-definitions)
  (check-equal? '("prices.py" 1)
                (list (buffers:name (views:buffer (servers:view))) (document:line (buffers:document (views:buffer (servers:view))) (views:point (servers:view)))))
  (test-user:press! "M-,"))

(test "completion of a name another module defines adds its import"
  (let ([main (servers:visit! (string-append shop "/main.py"))])
    (views:set-point! (servers:view) (- (document:length (buffers:document main)) 2))
    (test-user:press! "C-M-i")
    (test-runner:wait-until (lambda () (and (session) (not (completion:session-busy? (session))) (member "total" (texts)))))
    (let loop ([n 0])
      (unless (or (= n 200) (let ([m (completion:selected (session))]) (and m (equal? "total" (completion:text (session) m)))))
        (test-user:press! "M-n")
        (loop (+ n 1))))
    (test-user:press! "RET")
    (test-runner:wait-until (lambda () (string=? "from" (substring (servers:text main) 0 4))))
    (check-equal? "from prices import total\n\n\ndef run():\n    return total\n" (servers:text main))))

(test "rename across files, an open and an unopened one"
  (layout:switch-to-buffer cart)
  (views:set-point! (servers:view) (+ 1 (string-length "import os\nfrom prices import ")))
  (options:set! lsp:confirm-edits (lsp:confirmation never))
  (views:call-with-view (servers:view) (lambda () (lsp:rename "grand_total")))
  (options:unset! lsp:confirm-edits)
  (check-equal? '("import os\nfrom prices import grand_total\n\n\ndef checkout(items):\n    return grand_total(items)\n"
                  "def grand_total(items):\n    return sum(items)\n")
                (list (servers:text cart) (servers:text (files:buffer-visiting (string-append shop "/prices.py"))))))

(test "ruff formats on save"
  (buffers:with-buffer cart (hooks:add-local! files:before-save lsp:format-buffer))
  (buffers:replace! cart 1 1 "x=1\n")
  (views:call-with-view (servers:view) (lambda () (files:save-buffer cart)))
  (check-equal? "x = 1\n" (substring (call-with-input-file (string-append shop "/cart.py") get-string-all) 0 6))
  (buffers:with-buffer cart (hooks:remove-local! files:before-save lsp:format-buffer)))

(define (ruff-of b) (find (lambda (c) (eq? (lsp:connection-server c) lsp:ruff)) (lsp:buffer-connections b)))

(test "ruff with diagnostics, hover and formatting ignored is still offered formatting and still announces hover and formatting, and gives no diagnostic"
  (tables:set! lsp:servers lsp:ruff (lsp:server '("ruff" "server") (ignored-capabilities (lsp:capabilities diagnostics hover formatting))))
  (lsp:reconnect (ruff-of cart))
  (test-runner:wait-until (lambda () (let ([c (ruff-of cart)]) (and c (lsp:connection-capability c "textDocumentSync")))))
  (let ([c (ruff-of cart)])
    (check-equal? '(#t #t #t)
                  (list (and (assoc "formatting" (cdr (assoc "textDocument" (lsp:client-capabilities c)))) #t)
                        (and (lsp:connection-capability c "hoverProvider") #t)
                        (and (lsp:connection-capability c "documentFormattingProvider") #t))))
  (buffers:replace! cart 1 1 "import sys\n")
  ;; The claim is that ruff reports nothing, so the check waits for the
  ;; servers to have checked the edit.
  (timers:sleep 3)
  (check-equal? '(#f #t) (list (exists ruff-unused? (messages cart)) (and (exists basedpyright-unused? (messages cart)) #t)))
  (lsp:shutdown-all)
  (check-equal? '() (lsp:connections)))
