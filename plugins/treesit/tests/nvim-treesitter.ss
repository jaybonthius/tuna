(import (tuna) (test) (tables) (languages) (treesit) (python) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python python:python)
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (languages:grammar-commit python) grammar)

(define nvim-treesitter (string-append (path-parent (car (command-line))) "/plugins/treesit/src/treesit/nvim-treesitter"))

(test "every highlights query of nvim-treesitter reads in the dialect: compiled for Python's grammar, each fails, if at all, only on what tree-sitter itself checks"
  (let* ([root (string-append nvim-treesitter "/runtime/queries")]
         [all (filter file-exists?
                      (map (lambda (language) (format "~a/~a/highlights.scm" root language))
                           (list-sort string<? (directory-list root))))])
    (check (> (length all) 300))
    (check-equal? '("invalid node type")
      (fold-left
        (lambda (seen message) (if (member message seen) seen (cons message seen)))
        '()
        (apply append
          (map (lambda (file)
                 (let ([s (treesit-test/session:open grammar "x\n" (list file) '())])
                   (treesit-test/session:step! s)
                   (map (lambda (problem) (list-ref problem 4)) (treesit-test/session:problems s))))
               all))))))

;; nvim-treesitter names Python's revision by a tag, which an offline test
;; cannot resolve, so the tag is held beside the commit it named when the
;; pin was chosen.
(test "the grammar python pins is the repository and revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "python")])
    (check-equal? (languages:grammar-url python) url)
    (check-equal? "293fdc02038ee2bf0e2e206711b69c90ac0d413f" (languages:grammar-commit python))
    (check-equal? "v0.25.0" revision)))
