(import (tuna))
(use-plugin gen (git "https://github.com/bob/gen") (commit "4835765"))

(define (show path)
  (display (call-with-input-file (string-append (getenv "HOME") "/" path) get-string-all)))

(define (exists? path)
  (file-exists? (string-append (getenv "HOME") "/" path)))
(import (console))
