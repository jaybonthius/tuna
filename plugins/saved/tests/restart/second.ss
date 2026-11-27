(import (test) (saved) (saved-test util) (saved-test kept) (saved-test files))

(test "values set before an exit, on any thread and however large, are read after a restart"
  (check-equal? '("yes") (saved-test/kept:answers))
  (check-equal? 7 (saved-test/util:hits))
  (check-equal? 100000 (length (saved-test/kept:big))))

(test "the printer settings of the code that set a value do not change its file"
  (check-equal? "#foo" (symbol->string (car (saved-test/kept:odd)))))

(test "no temporary file is left"
  (check-equal? '()
    (let walk ([folder (saved-test/files:root)])
      (apply append
        (map (lambda (name)
               (let ([path (string-append folder "/" name)])
                 (cond
                   [(file-directory? path) (walk path)]
                   [(string=? (path-extension name) "new") (list path)]
                   [else '()])))
             (directory-list folder))))))
