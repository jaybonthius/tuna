(import (tuna) (test) (test-user) (test-runner) (options) (buffers) (layout) (files) (projects) (diagnostics)
        (completion-list) (diagnostic-picker) (completion-test picking))

(define (path name) (string-append (getenv "HOME") "/code/" name))

(define (write-file! name text)
  (call-with-output-file (path name) (lambda (p) (put-string p text)) 'replace))

(unless (file-exists? (path "")) (mkdir (path "")))
(write-file! ".project" "")
(write-file! "defs.txt" "def total\ndef average\ndef tally\n")
(write-file! "uses.txt" "x = total\ny = average + total\n")
(options:set! projects:extra-root-markers '(".project"))

(define source (diagnostics:make-source))

(define (listed) (map diagnostics:diagnostic-message (diagnostics:under (path ""))))

(test "C-u M-g f previews a diagnostic of a file no buffer visits in a temporary buffer, which a quit kills, and the file's diagnostics stay"
  (let ([uses (files:visit (path "uses.txt"))])
    (layout:switch-to-buffer uses)
    (buffers:with-buffer uses (options:set-local! diagnostics:mode #t))
    (diagnostics:report! source uses (list (diagnostics:make-diagnostic '(2 . 4) #f (diagnostics:severity warning) "average is slow")))
    (diagnostics:report! source (path "defs.txt") (list (diagnostics:make-diagnostic '(3 . 4) #f (diagnostics:severity error) "tally unused")))
    (check-equal? '("tally unused" "average is slow") (listed))
    (test-user:press! "C-u M-g f")
    (completion-test/picking:choices)
    (test-runner:wait-until (lambda () (buffers:find "defs.txt")))
    (check-equal? (list #t '("tally unused" "average is slow")) (list (files:temporary? (buffers:find "defs.txt")) (listed)))
    (check-equal? '(cancelled) (completion-test/picking:quit!))
    (check-equal? (list #f '("tally unused" "average is slow")) (list (buffers:find "defs.txt") (listed)))))
