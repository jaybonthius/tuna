(import (tuna) (test) (options) (hooks) (tables) (keys) (languages) (modes) (auto-mode) (prog) (buffers) (document) (files) (editing)
        (syntax) (syntax-highlighting) (ask) (chez-scheme) (chez-scheme-test scheme-buffers))

;; ask's own writer reports each message, such as the (New file) of
;; visiting a file that does not exist, as a warning, which would fail
;; the file.
(options:set! ask:message-writer (lambda (text) (void)))

(test "the mode has the parent prog:mode, its keymap and hook, the lighter Scheme and the language scheme; its hook runs after prog's"
  (check-equal? (list prog:mode "Scheme" "scheme")
                (list (tables:ref modes:parents chez-scheme:mode #f) (modes:lighter chez-scheme:mode) (languages:of chez-scheme:mode)))
  (check (eq? chez-scheme:keymap (tables:ref modes:keymaps chez-scheme:mode #f)))
  (check (eq? chez-scheme:mode-hook (tables:ref modes:hooks chez-scheme:mode #f)))
  (let ([order '()])
    (hooks:add! prog:mode-hook (lambda () (set! order (cons 'prog order))))
    (hooks:add! chez-scheme:mode-hook (lambda () (set! order (cons 'scheme order))))
    (chez-scheme-test/scheme-buffers:scheme-buffer "first.ss" "")
    (check-equal? '(prog scheme) (reverse order))))

(test "Scheme files get the mode by their names, and by the program a first line names"
  (mkdir (chez-scheme-test/scheme-buffers:home-file "src"))
  (let ([mode-of (lambda (name content)
                   (chez-scheme-test/scheme-buffers:write-text! (string-append "src/" name) content)
                   (modes:major-mode (files:visit (chez-scheme-test/scheme-buffers:home-file (string-append "src/" name)))))])
    (check-equal? (list chez-scheme:mode chez-scheme:mode chez-scheme:mode chez-scheme:mode chez-scheme:mode chez-scheme:mode modes:fundamental)
                  (map (lambda (name) (mode-of name "")) '("a.sls" "a.ss" "a.sps" "a.scm" "a.sch" "a.sld" "a.txt")))
    (check-equal? (make-list 7 chez-scheme:mode)
                  (map mode-of
                       '("tool" "lib" "script" "plain" "petite" "r6" "chez")
                       '("#!tuna\n" "#!tuna --script\n" "#!/usr/bin/env scheme-script\n" "#!/usr/bin/scheme --script\n"
                         "#!/usr/bin/petite --script\n" "#!r6rs\n" "#!chezscheme\n")))))

(test "a user maps another file name to the mode, and binds keys in its keymap"
  (tables:set! auto-mode:file-names "ms" chez-scheme:mode)
  (keys:bind! chez-scheme:keymap "C-c C-u" editing:upcase-region)
  (check-equal? chez-scheme:mode (modes:major-mode (files:visit (chez-scheme-test/scheme-buffers:home-file "notes.ms"))))
  (check-equal? (list (cons "C-c C-u" editing:upcase-region)) (keys:bindings chez-scheme:keymap)))

(test "words are as in other modes; symbols also hold R6RS's identifier characters, so the symbol at point is a whole name"
  (check-equal? (syntax:mode-word-characters modes:fundamental) (syntax:mode-word-characters chez-scheme:mode))
  (check-equal? "!$%&*/:<=>?^_~+-.@" (syntax:mode-symbol-characters chez-scheme:mode))
  (let ([s (chez-scheme-test/scheme-buffers:scheme-buffer "s.ss" "(buffers:insert! b \"x\") ; list->vector\n")])
    (check-equal? '("buffers:insert!" "list->vector")
                  (map (lambda (word)
                         (let-values ([(start end) (syntax:symbol-bounds s (chez-scheme-test/scheme-buffers:after s word))])
                           (document:text (buffers:document s) start end)))
                       '("(buf" "list->")))))

(test "the lexer gives each kind its class; a node's opening or closing is no character, and an atom lexes as part of a symbol"
  (define (classes doc)
    (map (lambda (l) (list (syntax:lexeme-class l) (syntax:lexeme-start l) (syntax:lexeme-end l)))
         (vector->list (chez-scheme:lexer doc))))
  (check-equal? '((open 0 1) (atom 1 2) (prefix 3 4) (atom 4 5) (string 6 9) (comment 10 13) (comment 15 18) (atom 19 24)
                  (atom 25 28) (atom 29 31) (atom 32 33) (atom 34 35) (close 35 36))
                (classes (document:from-datum "(a 'b \"c\" ; d\n #;e #!eof #\\x #t . 1)")))
  (check-equal? '((open 1 2) (atom 2 4) (atom 5 6) (close 6 7) (atom 9 10))
                (classes (document:from-datum '(p () "(a" #(img ()) " b)") '(p () "c"))))
  (check-equal? '(#t) (map syntax:lexeme-open-ended? (vector->list (chez-scheme:lexer (document:from-datum "\"a ; b\n; c"))))))

(test "the lexer is syntax's for the mode, and its lexemes carry their class, start, end and depth"
  (check (eq? chez-scheme:lexer (syntax:lexer chez-scheme:mode)))
  (let ([l (vector-ref (chez-scheme:lexer (buffers:document (buffers:make "lexed.ss" "(car '(a b))\n"))) 2)])
    (check-equal? '(prefix 6 7 1) (list (syntax:lexeme-class l) (syntax:lexeme-start l) (syntax:lexeme-end l) (syntax:lexeme-depth l)))))

(test "the plugin registers a highlighter for the mode"
  (check (syntax-highlighting:highlighter? (tables:ref syntax-highlighting:highlighters chez-scheme:mode #f))))
