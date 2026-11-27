#!tuna
(import (processes))

(define (%run! program . arguments)
  (let-values ([(status output errors) (processes:run program arguments)])
    (unless (eqv? status 0)
      (error 'treesit-test/grammar:build-python! (utf8->string output) (cons program arguments)))))

(define (%make-folders! path)
  (let loop ([d (path-parent path)])
    (unless (or (string=? d "") (file-directory? d))
      (loop (path-parent d))
      (mkdir d))))

;; No test fetches a grammar: tree-sitter-python is built from the copy
;; chez-treesitter vendors, at the commit given, as treesit-install would
;; build it from its repository.
(define (build-python! commit file)
  (unless (file-exists? file)
    (let* ([install (path-parent (car (command-line)))]
           [checkout (string-append install "/libraries/chez-treesitter/vendor/tree-sitter-python")]
           [scratch (string-append (getenv "HOME") "/tree-sitter-python")]
           [archive (string-append scratch ".tar")]
           [scanner (string-append scratch "/src/scanner.c")])
      (mkdir scratch)
      (%run! "git" "-C" checkout "archive" "-o" archive commit "src")
      (%run! "tar" "-x" "-f" archive "-C" scratch)
      (%make-folders! file)
      (apply %run! "cc" "-O2" "-std=c11" "-fPIC" "-shared" (string-append "-I" scratch "/src") "-o" file
             (string-append scratch "/src/parser.c")
             (if (file-exists? scanner) (list scanner) '())))))
