(import (tuna) (buffers) (files) (modes) (auto-mode) (python) (modes-test text))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(call-with-output-file (home-file "a.py") (lambda (p) (put-string p "print(1)\n")) 'replace)

(modes:set-major-mode modes-test/text:mode (files:visit (home-file "a.py")))

(modes:set-major-mode modes-test/text:mode (buffers:make "notes" "Buy milk.\n"))
