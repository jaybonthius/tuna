(import (tuna) (saved) (saved-test util) (saved-test kept))

(saved:set! saved-test/kept:answers '("yes"))
(join-task (fork-task (lambda (restore) (saved:set! saved-test/util:hits 7))))
(saved:set! saved-test/kept:big (make-list 100000 "a line of text in a long history"))
(parameterize ([print-extended-identifiers #t])
  (saved:set! saved-test/kept:odd (list (string->symbol "#foo"))))
