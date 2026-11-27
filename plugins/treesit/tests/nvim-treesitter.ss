(import (tuna) (test) (tables) (treesit) (treesit-test grammar) (treesit-test session))

(define python (tables:ref treesit:grammars "python" #f))
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) grammar)

(define nvim-treesitter (string-append (path-parent (car (command-line))) "/plugins/treesit/src/treesit/nvim-treesitter"))

(define (index-of text needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length text)) #f]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

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
(test "the grammar treesit pins for Python is the repository and revision nvim-treesitter's queries were written for"
  (let* ([parsers (call-with-input-file (string-append nvim-treesitter "/lua/nvim-treesitter/parsers.lua") get-string-all)]
         [at (index-of parsers "\n  python = {" 0)]
         [end (index-of parsers "\n  },\n" at)]
         [entry (lambda (key)
                  (let ([k (index-of parsers (string-append key " = '") at)])
                    (and k (< k end)
                         (let ([from (+ k (string-length key) 4)])
                           (substring parsers from (index-of parsers "'" from))))))])
    (check-equal? (treesit:grammar-source python) (entry "url"))
    (check-equal? "293fdc02038ee2bf0e2e206711b69c90ac0d413f" (treesit:grammar-commit python))
    (check-equal? "v0.25.0" (entry "revision"))))
