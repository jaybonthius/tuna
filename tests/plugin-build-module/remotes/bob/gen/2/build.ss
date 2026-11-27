(unless (file-directory? "src") (mkdir "src"))
(with-output-to-file "src/gen.sls"
  (lambda () (display "#!tuna\n(define (version) 2)\n"))
  'replace)
(display "wrote src/gen.sls\n")
