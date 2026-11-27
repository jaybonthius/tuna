(import (tuna) (test) (span-checks) (emacs-checks))

(test "the span store agrees with a plain list on random adds, maps by stickiness, splits, takes and queries, small and large"
  (check-equal? '(0 0) (map (lambda (seed) (cadr (span-checks seed))) '(1 2))))

(test "layers move as Emacs moves overlays, on the same random edits, recorded from Emacs"
  (check-equal? (make-list 5 #t) (emacs-checks:overlay-results)))

(test "travelling layers move as Emacs moves a text property under typing, insertion, cuts, undo and yanks, recorded from Emacs"
  (check-equal? (make-list 20 #t) (emacs-checks:text-property-results)))
