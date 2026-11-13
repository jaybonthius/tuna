(unless (file-directory? "src/adder") (mkdir "src/adder"))
(with-output-to-file "src/adder/built.ss"
  (lambda () (write `(define adder-built-with ,(scheme-version))))
  'replace)
