(import (test))

(test "a second file run on one home finds what the first left"
  (check-equal? 'kept (call-with-input-file (string-append (getenv "HOME") "/kept") read)))
