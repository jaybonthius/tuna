(import (tuna) (test) (git-status-test patches))

(define (trial-run seed)
  (let ([r (git-status-test/patches:run-random! "random" seed 8 40)])
    (list (> (cadr r) 250) (cadddr r))))

(test "random selections of lines and hunks, staged, unstaged and discarded over rounds of random edits to CRLF files, files without a final newline, renames, new and deleted files, leave what a line model gives"
  (for-each (lambda (seed) (check-equal? '(#t ()) (trial-run seed))) '(1 7 42)))
