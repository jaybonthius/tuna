(import (test) (document-test model))

(test "random documents and edits answer every query as a flat list of their tokens does"
  (let-values ([(checks failures) (edit-checks 1 12 30 12)])
    (check-equal? '() failures)
    (check (> checks 100000))))

(test "typing and deleting at one place, which splits and shrinks runs, answers every query as the flat list does"
  (let-values ([(checks failures) (typing-checks 2 6000 15)])
    (check-equal? '() failures)
    (check (> checks 2000))))
