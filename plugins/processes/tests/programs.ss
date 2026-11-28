(import (tuna) (test) (processes) (buffers-test))

(define home (getenv "HOME"))

(define (write-program! path)
  (call-with-output-file path (lambda (p) (put-string p "#!/bin/sh\n")) 'replace))

(mkdir (string-append home "/one"))
(mkdir (string-append home "/two"))
(mkdir (string-append home "/two/folder-tool"))
(write-program! (string-append home "/two/tool"))
(write-program! (string-append home "/one/first"))
(write-program! (string-append home "/two/first"))

(define path (getenv "PATH"))

(test "program-path finds a program in the first folder of PATH that holds it, skipping folders and empty entries"
  (putenv "PATH" (string-append ":" home "/one:" home "/two"))
  (check-equal? (list (string-append home "/two/tool") (string-append home "/one/first") #f #f)
                (map processes:program-path '("tool" "first" "folder-tool" "nowhere")))
  (putenv "PATH" path))

(test "a program named with a / is itself when it is a file"
  (check-equal? (list (string-append home "/two/tool") #f)
                (map processes:program-path (list (string-append home "/two/tool") (string-append home "/two/none")))))

(test "the argument is checked"
  (check-raises (buffers-test:raised? 'processes:program-path "not a program's name") (processes:program-path ""))
  (check-raises (buffers-test:raised? 'processes:program-path "not a program's name") (processes:program-path 'git)))
