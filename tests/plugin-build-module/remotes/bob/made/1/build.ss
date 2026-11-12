(with-output-to-file "made.sls"
  (lambda () (display "#!tuna\n(define (where) \"built\")\n"))
  'replace)
(display "wrote made.sls\n")
