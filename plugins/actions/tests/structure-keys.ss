(import (tuna) (test) (keys) (completion) (editing) (sexp) (comment) (actions))

(define (bound keymap key) (cdr (assoc key (keys:bindings keymap))))

(test "a region's actions indent it, move its lines a column, and comment it"
  (check-equal? (list editing:indent-region editing:indent-rigidly-left editing:indent-rigidly-right comment:dwim)
                (map (lambda (key) (bound completion:region-action-keymap key)) '("TAB" "<left>" "<right>" ";"))))

(test "an expression's actions indent, comment, raise and transpose it, and move up or past lists"
  (check-equal? (list editing:indent-region comment:dwim sexp:raise sexp:transpose sexp:backward-up-list sexp:forward-list
                      sexp:backward-list)
                (map (lambda (key) (bound completion:expression-action-keymap key)) '("TAB" ";" "r" "t" "u" "n" "p"))))
