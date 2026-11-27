(unless (file-directory? "src") (mkdir "src"))
(with-output-to-file "src/made.sls"
  (lambda () (display "#!tuna\n(define (where) \"built\")\n"))
  'replace)
(display "wrote src/made.sls\n")
