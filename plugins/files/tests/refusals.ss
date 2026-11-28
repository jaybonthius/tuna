(import (tuna) (test) (eval-test caught-reports) (test-runner) (test-user) (options) (ask) (buffers) (layout) (echo-area)
        (files) (files-test))

(define (refused keys)
  (echo-area:message! "")
  (let ([reports (eval-test/caught-reports:during
                   (lambda ()
                     (test-user:press! keys)
                     (test-runner:wait-until echo-area:current-message)))])
    (list (echo-area:current-message) (length reports))))

(define draft (buffers:make "*draft*" "draft"))

(test "a no to replacing a file C-x C-w names says Canceled, and nothing is written"
  (files-test:write-text! "~/taken.txt" "taken\n")
  (layout:switch-to-buffer draft)
  (options:set! ask:file-name-reader (files-test:answer "~/taken.txt"))
  (options:set! ask:y-or-n-reader (files-test:answer #f))
  (check-equal? '("Canceled" 1) (refused "C-x C-w"))
  (check-equal? '(("Write file: " "File exists; overwrite? ") "taken\n") (list (files-test:questions) (files-test:read-text "~/taken.txt"))))

(test "C-x x g in a buffer that visits no file says so, naming the buffer"
  (check-equal? '("*draft* visits no file" 1) (refused "C-x x g")))

(test "C-x C-w of a file another buffer visits names that buffer and the file, and asks nothing"
  (files:visit "~/taken.txt")
  (check-equal? '("Buffer taken.txt already visits ~/taken.txt" 1) (refused "C-x C-w"))
  (check-equal? '(("Write file: ") #f) (list (files-test:questions) (files:path draft))))

(define loose (buffers:make "*loose*" ""))

(test "C-x C-s of a buffer that visits no file, answered with a folder, says it is a folder, naming it"
  (buffers:replace! loose 1 1 "loose")
  (layout:switch-to-buffer loose)
  (options:set! ask:file-name-reader (files-test:answer "~/"))
  (check-equal? (list (string-append (files:abbreviated-path (getenv "HOME")) " is a folder") 1) (refused "C-x C-s"))
  (check-equal? '(("File to save in: ") #f) (list (files-test:questions) (files:path loose))))
