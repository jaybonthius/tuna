(import (tuna))
(use-plugin wrap (git "https://github.com/bob/wrap") (commit "e628184"))
(use-plugin loc (local "~/src/loc"))

(define (show path)
  (display (call-with-input-file (string-append (getenv "HOME") "/" path) get-string-all)))

(define (exists? path)
  (file-exists? (string-append (getenv "HOME") "/" path)))
(import (console))
