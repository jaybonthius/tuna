#!tuna

(define (%found? program)
  (let loop ([folders (let split ([s (or (getenv "PATH") "")] [start 0] [i 0])
                        (cond
                          [(= i (string-length s)) (list (substring s start i))]
                          [(char=? (string-ref s i) #\:) (cons (substring s start i) (split s (+ i 1) (+ i 1)))]
                          [else (split s start (+ i 1))]))])
    (and (pair? folders)
         (or (file-exists? (string-append (car folders) "/" program))
             (loop (cdr folders))))))

;; A server is not Tuna's to ship, but a test that needs one fails without
;; it, so a machine missing it shows a failure rather than a pass.
(define (require-programs! programs)
  (for-each
    (lambda (program)
      (unless (%found? program)
        (error 'lsp-test/installed:require-programs! "not installed, which this test needs" program)))
    programs))
