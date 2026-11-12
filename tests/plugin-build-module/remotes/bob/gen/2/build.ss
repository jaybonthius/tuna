(with-output-to-file "gen.sls"
  (lambda () (display "#!tuna\n(define (version) 2)\n"))
  'replace)
(display "wrote gen.sls\n")
