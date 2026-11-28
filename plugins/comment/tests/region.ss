(import (tuna) (test) (test-user) (editing) (comment) (editing-test scene) (sexp-test scene))

(test "comment:region comments the region's lines"
  (sexp-test/scene:show! "(a)\n|(b)\n(c)@")
  (editing-test/scene:run comment:region)
  (check-equal? "(a)\n|;; (b)\n;; (c)" (sexp-test/scene:shown)))

(test "comment:uncomment-region uncomments the region's lines"
  (sexp-test/scene:show! ";; (a)\n|;; (b)\n;; (c)@")
  (editing-test/scene:run comment:uncomment-region)
  (check-equal? ";; (a)\n|(b)\n(c)" (sexp-test/scene:shown)))

(test "comment:region with no mark raises"
  (sexp-test/scene:show! "(a)|")
  (check-equal? '((comment:region "the mark is not set, so there is no region"))
                (editing-test/scene:reports-during (lambda () (editing-test/scene:run comment:region)))))
