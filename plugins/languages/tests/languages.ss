(import (tuna) (test) (languages) (modes) (prog) (hooks) (tables) (buffers-test) (languages-test shellish) (languages-test envish))

(define shellish languages-test/shellish:mode)
(define envish languages-test/envish:mode)

(define (delimiter-fields d)
  (list (languages:delimiter-start d) (languages:delimiter-end d) (languages:delimiter-escape d)
        (languages:delimiter-word-start? d) (languages:delimiter-line-bound? d)))

(test "define-language sets one entry per clause, keyed by the language"
  (check-equal? shellish (tables:ref languages:mode "shellish" #f))
  (check-equal? '("shellish" ".shellishrc") (tables:ref languages:file-names "shellish" #f))
  (check-equal? '("shellish") (tables:ref languages:interpreters "shellish" #f))
  (check (eq? languages-test/shellish:shellish (tables:ref languages:grammar "shellish" #f)))
  (check-equal? '(("#" #f #f #t #f)) (map delimiter-fields (tables:ref languages:line-comments "shellish" #f)))
  (check-equal? '(("\"" "\"" #\\ #f #f) ("'" "'" #f #f #f)) (map delimiter-fields (tables:ref languages:strings "shellish" #f)))
  (check-equal? '((#\( . #\)) (#\{ . #\})) (tables:ref languages:brackets "shellish" #f))
  (check-equal? "_-" (tables:ref languages:symbol-characters "shellish" #f))
  (check-equal? '(#f #f) (map (lambda (t) (tables:ref t "shellish" #f)) (list languages:block-comments languages:word-characters))))

(test "a grammar is named by its identifier, with its source and commit, and location . unless given"
  (let ([g languages-test/shellish:shellish])
    (check (languages:grammar? g))
    (check-equal? '("shellish" "https://example.org/tree-sitter-shellish" "0123456789abcdef0123456789abcdef01234567" "." #f)
                  (list (languages:grammar-name g) (languages:grammar-url g) (languages:grammar-commit g)
                        (languages:grammar-location g) (languages:grammar-prebuilt g)))))

(languages:define-grammar parts (git "https://example.org/parts" "89abcdef0123456789abcdef0123456789abcdef" "parts/inline"))
(languages:define-grammar built (file "/opt/grammars/libtree-sitter-built.so"))

(test "a grammar may name the folder that holds its parser, or the shared object built elsewhere"
  (check-equal? '("parts" "parts/inline") (list (languages:grammar-name parts) (languages:grammar-location parts)))
  (check-equal? '("built" #f #f #f "/opt/grammars/libtree-sitter-built.so")
                (list (languages:grammar-name built) (languages:grammar-url built) (languages:grammar-commit built)
                      (languages:grammar-location built) (languages:grammar-prebuilt built))))

(test "a grammar's source and commit are checked when it is made"
  (for-each
    (lambda (module message irritants)
      (check-raises (buffers-test:raised-with? 'languages:define-grammar message irritants)
                    (load-module! (list 'languages-test 'bad module))))
    '(grammar-commit grammar-url grammar-file)
    '("not a full commit: 40 hexadecimal digits" "not a URL or folder" "not a file name")
    '(("293fdc0") (url) (#f))))

(test "a malformed form is a syntax error naming it, when it expands"
  (for-each
    (lambda (module message)
      (check-raises (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c))))
                    (load-module! (list 'languages-test 'bad module))))
    '(grammar-name grammar-source flag comment-escape flag-twice string-no-end brackets twice unknown)
    '("a grammar's name holds letters, digits and _ only" "expected (git url commit [location]) or (file path)"
      "invalid flag" "invalid flag" "invalid flag" "invalid delimiter" "not a string of one character" "clause given twice"
      "invalid clause")))

(test "a clause's value is checked as the form runs, naming the form"
  (check-raises (buffers-test:raised-with? 'languages:define-language "not a mode" '(nothing:mode))
                (let () (languages:define-language "x" (mode 'nothing:mode)) #f))
  (check-raises (buffers-test:raised? 'languages:define-language "not a list of file name patterns")
                (let () (languages:define-language "x" (file-names "a" "")) #f))
  (check-raises (buffers-test:raised? 'languages:define-language "not a grammar")
                (let () (languages:define-language "x" (grammar "bash")) #f))
  (check-raises (buffers-test:raised? 'languages:define-language "not a language")
                (let () (languages:define-language 'x (word-characters "")) #f))
  (check-equal? #f (tables:ref languages:mode "x" #f)))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")
(modes:define-major-mode child (parent shellish) (keymap keymap) (hook hook))
(modes:define-major-mode twin (keymap keymap) (hook hook))

(test "a mode's language is the one whose mode is the first in its ancestry that one names, so a derived mode edits its parent's"
  (check-equal? '("shellish" "shellish" "envish" #f #f)
                (map languages:of (list shellish child envish prog:mode modes:fundamental)))
  (check-raises (buffers-test:raised? 'languages:of "not a mode") (languages:of "shellish")))

(test "of two languages that name one mode, the first declared is its language"
  (languages:define-language "twin-a" (mode twin))
  (languages:define-language "twin-b" (mode twin))
  (check-equal? "twin-a" (languages:of twin)))

(test "a configuration's form sets only the facts it names; the plugin's others stay, and unloading it restores the plugin's"
  (let ([configuration (make-owner '(configuration))])
    (call-as-owner configuration
      (lambda () (languages:define-language "shellish" (file-names "shellish" "shellishx") (word-characters "$")) (void)))
    (check-equal? '("shellish" "shellishx") (tables:ref languages:file-names "shellish" #f))
    (check-equal? "$" (tables:ref languages:word-characters "shellish" #f))
    (check (eq? languages-test/shellish:shellish (tables:ref languages:grammar "shellish" #f)))
    (check-equal? shellish (tables:ref languages:mode "shellish" #f))
    (unload-owner! configuration)
    (check-equal? '("shellish" ".shellishrc") (tables:ref languages:file-names "shellish" #f))
    (check-equal? #f (tables:ref languages:word-characters "shellish" #f))))

(test "a language that borrows a grammar names it through its plugin, and a reload of that plugin reloads the borrower, so both name the grammar it defines"
  (check (eq? languages-test/shellish:shellish (tables:ref languages:grammar "envish" #f)))
  (reload-modules! '((languages-test shellish)))
  (check (eq? languages-test/shellish:shellish (tables:ref languages:grammar "envish" #f)))
  (check (eq? (tables:ref languages:grammar "shellish" #f) (tables:ref languages:grammar "envish" #f))))

(test "unloading the declaring plugin takes its entries back"
  (unload-owner! (module-owner '(languages-test envish)))
  (check-equal? '(#f #f #f) (map (lambda (t) (tables:ref t "envish" #f)) (list languages:mode languages:file-names languages:grammar))))

(test "each fact has a checked reader: the entry, else the empty value, raising for an entry of another shape, naming the language"
  (check-equal? '(("shellish" ".shellishrc") ("shellish") (#\( #\{) "_-" #f)
                (list (languages:file-names-of "shellish") (languages:interpreters-of "shellish")
                      (map car (languages:brackets-of "shellish")) (languages:symbol-characters-of "shellish")
                      (languages:word-characters-of "shellish")))
  (check-equal? '(("#") () ("\"" "'"))
                (map (lambda (ds) (map languages:delimiter-start ds))
                     (list (languages:line-comments-of "shellish") (languages:block-comments-of "shellish")
                           (languages:strings-of "shellish"))))
  (check (eq? languages-test/shellish:shellish (languages:grammar-of "shellish")))
  (check-equal? '(() () () () () () #f #f #f)
                (list (languages:file-names-of "none") (languages:interpreters-of "none") (languages:line-comments-of "none")
                      (languages:block-comments-of "none") (languages:strings-of "none") (languages:brackets-of "none")
                      (languages:word-characters-of "none") (languages:symbol-characters-of "none") (languages:grammar-of "none")))
  (let ([configuration (make-owner '(configuration))])
    (call-as-owner configuration
      (lambda ()
        (for-each (lambda (t) (tables:set! t "broken" 'junk))
                  (list languages:file-names languages:interpreters languages:line-comments languages:block-comments
                        languages:strings languages:brackets languages:word-characters languages:symbol-characters
                        languages:grammar))))
    (for-each
      (lambda (read who message)
        (check-raises (buffers-test:raised-with? who message '("broken" junk)) (read "broken")))
      (list languages:file-names-of languages:interpreters-of languages:line-comments-of languages:block-comments-of
            languages:strings-of languages:brackets-of languages:word-characters-of languages:symbol-characters-of
            languages:grammar-of)
      '(languages:file-names-of languages:interpreters-of languages:line-comments-of languages:block-comments-of
        languages:strings-of languages:brackets-of languages:word-characters-of languages:symbol-characters-of
        languages:grammar-of)
      '("the entry is not a list of file name patterns" "the entry is not a list of programs"
        "the entry is not a list of delimiters" "the entry is not a list of delimiters" "the entry is not a list of delimiters"
        "the entry is not a list of pairs of characters" "the entry is not a string" "the entry is not a string"
        "the entry is not a grammar"))
    (unload-owner! configuration))
  (check-raises (buffers-test:raised? 'languages:strings-of "not a language") (languages:strings-of 'shellish)))
