(call-with-output-file (string-append (getenv "HOME") "/kept") (lambda (p) (write 'kept p)))
