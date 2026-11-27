(when (file-exists? "src/gen.sls") (delete-file "src/gen.sls"))
(unless (file-directory? "out") (mkdir "out"))
(with-output-to-file "out/gen.sls"
  (lambda () (display "#!tuna\n(define (version) 3)\n"))
  'replace)
(display "wrote out/gen.sls\n")
