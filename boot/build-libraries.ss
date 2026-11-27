;; The copies Tuna comes with are never installed, so they are built here
;; as an install builds a library, except that Tuna's own checkout has
;; fetched their submodules.
(define-values (program libraries deps logs) (apply values (command-line-arguments)))

;; The plugin manager's own libraries are in the start folder beside the
;; program.
(library-directories
  (cons (let ([start (string-append (path-parent program) "/start")]) (cons start start))
        (library-directories)))
(import (plugins installs))

(call-with-input-file deps
  (lambda (p)
    (let loop ()
      (let ([line (read p)])
        (unless (eof-object? line)
          (let* ([id (symbol->string (cadr line))]
                 [folder (string-append libraries "/" id)]
                 [build (assq 'build (cddr line))]
                 [log (string-append logs "/" id ".log")])
            (delete-file log #f)
            (run-build! 'build-libraries (format "library ~a" id) folder folder (and build (cdr build)) program log))
          (loop))))))
