(import (tuna) (test) (languages) (modes) (prog) (buffers) (document) (hooks) (tables) (syntax) (chez-scheme) (buffers-test) (syntax-test)
        (chez-scheme-test scheme-buffers))

(define after syntax-test:after)

(tables:define-table derived-keymap)
(hooks:define-hook derived-hook)
(modes:define-major-mode derived (parent chez-scheme:mode) (keymap derived-keymap) (hook derived-hook))

(define (bounds b position . mode) (call-with-values (lambda () (apply syntax:symbol-bounds b position mode)) list))

(define (symbol-at b position . mode)
  (let ([r (apply bounds b position mode)])
    (and (car r) (syntax-test:between b (car r) (cadr r)))))

(test "a mode's characters are the first in its ancestry with an entry, else its language's, else modes:fundamental's, Emacs's standard syntax table's"
  (check-equal? '("$%" "_-+*/&|<>=") (list (syntax:mode-word-characters modes:fundamental) (syntax:mode-symbol-characters modes:fundamental)))
  (check-equal? "_-+*/&|<>=" (syntax:mode-symbol-characters prog:mode))
  (check-equal? '("$%" "!$%&*/:<=>?^_~+-.@") (list (syntax:mode-word-characters derived) (syntax:mode-symbol-characters derived)))
  (let ([configuration (make-owner '(configuration))])
    (call-as-owner configuration (lambda () (tables:set! languages:symbol-characters "scheme" "!")))
    (check-equal? "!" (syntax:mode-symbol-characters derived))
    (tables:set! syntax:symbol-characters derived "-")
    (check-equal? "-" (syntax:mode-symbol-characters derived))
    (tables:remove! syntax:symbol-characters derived)
    (unload-owner! configuration))
  (check-equal? "!$%&*/:<=>?^_~+-.@" (syntax:mode-symbol-characters derived)))

(define s (chez-scheme-test/scheme-buffers:scheme-buffer "s.ss" "(buffers:insert! b \"x\") ; list->vector\n"))

(test "the symbol around a position, with the buffer's mode, holding or touching it; none at a blank between others"
  (check-equal? '("buffers:insert!" "buffers:insert!" "buffers:insert!" "x" "list->vector")
                (map (lambda (p) (symbol-at s p)) (list (after s "(buf") (after s "(") (after s "insert!") (after s "x") (after s "list->"))))
  (check-equal? '(#f #f) (bounds s (after s "b "))))

(define plain (buffers:make "plain" "(buffers:insert! b)"))

(test "a plain buffer reads its own mode's characters unless asked with another mode's"
  (check-equal? '("buffers" "insert") (list (symbol-at plain (after plain "(buf")) (symbol-at plain (after plain "ins"))))
  (check-equal? "buffers:insert!" (symbol-at plain (after plain "ins") chez-scheme:mode)))

(test "a user changes the default for every mode without an entry of its own"
  (tables:set! syntax:symbol-characters modes:fundamental "_-+*/&|<>=:!")
  (check-equal? "buffers:insert!" (symbol-at plain (after plain "ins")))
  (tables:remove! syntax:symbol-characters modes:fundamental)
  (check-equal? "insert" (symbol-at plain (after plain "ins"))))

(test "a buffer's own characters are its mode's unless advice answers for it; asking with a mode reads that mode's"
  (check-equal? '("$%" "!$%&*/:<=>?^_~+-.@") (list (syntax:buffer-word-characters plain) (syntax:buffer-symbol-characters s)))
  (let ([colons-in-plain (lambda (symbol-characters buffer)
                           (if (eq? buffer plain) (string-append (symbol-characters buffer) ":!") (symbol-characters buffer)))])
    (advice-add! syntax:buffer-symbol-characters colons-in-plain)
    (check-equal? '("buffers:insert!" "insert") (list (symbol-at plain (after plain "ins")) (symbol-at plain (after plain "ins") modes:fundamental)))
    (advice-remove! syntax:buffer-symbol-characters colons-in-plain)))

(test "the documented minor mode that makes each symbol one word, by advice"
  (let ([symbol-words (lambda (word-characters buffer)
                        (string-append (word-characters buffer) (syntax:buffer-symbol-characters buffer)))])
    (advice-add! syntax:buffer-word-characters symbol-words)
    (check-equal? "$%!$%&*/:<=>?^_~+-.@" (syntax:buffer-word-characters s))
    (advice-remove! syntax:buffer-word-characters symbol-words)))

(test "a node's edge ends the run"
  (let ([nested (buffers:make "nested" '(buffers:text () "ab" (buffers:text () "cd")))])
    (check-equal? '((1 3) (4 6) (1 3)) (list (bounds nested 2) (bounds nested 5) (bounds nested 3)))))

(test "the checks"
  (check-raises (buffers-test:raised? 'syntax:buffer-word-characters "not a buffer") (syntax:buffer-word-characters 'plain))
  (let ([not-a-string (lambda (symbol-characters buffer) 'colon)])
    (advice-add! syntax:buffer-symbol-characters not-a-string)
    (check-raises (buffers-test:raised? 'syntax:symbol-bounds "the characters are not strings") (syntax:symbol-bounds plain 3))
    (advice-remove! syntax:buffer-symbol-characters not-a-string))
  (check-raises (buffers-test:raised? 'syntax:symbol-bounds "not a buffer") (syntax:symbol-bounds 'b 1))
  (check-raises (buffers-test:raised? 'syntax:symbol-bounds "not a position in the buffer") (syntax:symbol-bounds s 1000))
  (check-raises (buffers-test:raised? 'syntax:symbol-bounds "not a mode") (syntax:symbol-bounds s 1 "scheme"))
  (check-equal? '(syntax:symbol-bounds "not on the main thread") (buffers-test:on-thread (lambda () (syntax:symbol-bounds s 1))))
  (tables:set! syntax:word-characters derived 'dollar)
  (check-raises (buffers-test:raised? 'syntax:mode-word-characters "the mode's entry is not a string") (syntax:mode-word-characters derived))
  (tables:remove! syntax:word-characters derived))

(test "a mode's characters are read on any thread"
  (check-equal? "!$%&*/:<=>?^_~+-.@" (let ([r #f]) (join-task (fork-task (lambda (restore) (set! r (syntax:mode-symbol-characters chez-scheme:mode))))) r)))
