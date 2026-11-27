(import (tuna) (test) (test-runner) (hooks) (tables) (modes) (buffers) (document) (syntax) (syntax-highlighting)
        (chez-scheme) (scheme-buffers))

;; Highlighting runs in a job, so each check waits until the spans are
;; the ones it expects.
(define (faces-become b expected)
  (test-runner:wait-until (lambda () (equal? expected (scheme-buffers:faces b)))))

(define (brackets-become b expected)
  (test-runner:wait-until (lambda () (equal? expected (scheme-buffers:brackets b)))))

(tables:define-table derived-keymap)

(hooks:define-hook derived-hook)

(modes:define-major-mode derived (parent chez-scheme:mode) (keymap derived-keymap) (hook derived-hook))

(test "a buffer whose mode derives from the mode is highlighted by a job, each kind of text in its face"
  (let ([h (buffers:make "h.ss" "; c\n#| b |# #;(x y) (f \"s\\n\\x3bb;t\" #\\a 1.5 #t #!r6rs #!eof '#0=(a) #0# `(b ,c ,@d) #'e)\n")])
    (modes:set-major-mode derived h)
    (faces-become h '(("; c" comment) ("#| b |#" comment) ("#;(x y)" comment) ("\"s" string) ("\\n" string.escape)
                      ("\\x3bb;" string.escape) ("t\"" string) ("#\\a" character) ("1.5" number) ("#t" boolean)
                      ("#!r6rs" keyword.directive) ("#!eof" constant.builtin) ("'" punctuation.special)
                      ("#0=" punctuation.special) ("a" string.special.symbol) ("#0#" punctuation.special)
                      ("`" punctuation.special) ("b" string.special.symbol) ("," punctuation.special)
                      (",@" punctuation.special) ("#'" punctuation.special)))))

(define n
  (scheme-buffers:scheme-buffer "n.ss"
    (string-append
      "(define (area r) \"The area.\" (* r r))\n(define pi 3.14)\n(define-record-type point (fields x))\n"
      "(define-enumeration color (red) colors)\n(modes:define-major-mode python (keymap k))\n(define ((curried a) b) a)\n"
      "(let loop ([i 0]) (loop i))\n(library (my lib) (export) (import (rnrs)))\n(define (two) \"only a string\")\n"
      "(#%car #2%cdr #3%map)\n")))

(define n-faces
  '(("define" keyword) ("area" function) ("\"The area.\"" comment.documentation) ("*" function.builtin) ("define" keyword)
    ("pi" function) ("3.14" number) ("define-record-type" keyword) ("point" type) ("fields" keyword)
    ("define-enumeration" keyword) ("color" type) ("python" function) ("define" keyword) ("let" keyword) ("loop" function)
    ("0" number) ("my" module) ("lib" module) ("define" keyword) ("two" function) ("\"only a string\"" string)
    ("#%car" function.builtin) ("#2%cdr" function.builtin) ("#3%map" function.builtin)))

(test "definitions' names, documentation, named lets, library names and primitives; a library form gives the scope, here (rnrs)"
  (faces-become n n-faces))

(test "a mode change to another stops the job and takes the spans away; back in the mode the buffer is highlighted again"
  (modes:set-major-mode modes:fundamental n)
  (faces-become n '())
  (modes:set-major-mode chez-scheme:mode n)
  (faces-become n n-faces))

(test "bracket spans come while a plugin uses brackets, and go with the job"
  (let ([k (scheme-buffers:scheme-buffer "k.ss" "(a [b])")])
    (tables:set! syntax:bracket-users 'test (lambda (buffer) (eq? buffer k)))
    (syntax-highlighting:update!)
    (test-runner:wait-until (lambda () (= 4 (length (scheme-buffers:brackets k)))))
    (check-equal? '((bracket . 1) (bracket . 2) (bracket . 2) (bracket . 1)) (map caaddr (scheme-buffers:brackets k)))
    (modes:set-major-mode modes:fundamental k)
    (brackets-become k '())
    (tables:remove! syntax:bracket-users 'test)
    (syntax-highlighting:update!)))

(test "after an edit the job lexes the newest text, and the faces follow; text typed right after a lexeme takes its face until then"
  (let ([w (scheme-buffers:scheme-buffer "w.ss" "(car x)\n")])
    (faces-become w '(("car" function.builtin)))
    (buffers:replace! w 5 5 "-or-cdr")
    (check-equal? (list (list 2 12 (list (cons 'face 'function.builtin))))
                  (buffers:spans (buffers:layer w syntax-highlighting:faces) 0 15))
    (faces-become w '())
    (buffers:replace! w 1 1 "'")
    (faces-become w '(("'" punctuation.special) ("car-or-cdr" string.special.symbol) ("x" string.special.symbol)))
    (let ([copy (buffers:make "copy" "\n")])
      (buffers:insert! copy 1 (buffers:piece w 2 12))
      (check-equal? '() (buffers:layers copy)))))

(test "the job is told where each edit was, so a space typed after a lexeme, among other spaces, loses the lexeme's face at the next lex"
  (let ([sp (scheme-buffers:scheme-buffer "sp.ss" "(car   x)\n")])
    (faces-become sp '(("car" function.builtin)))
    (buffers:replace! sp 5 5 " ")
    (buffers:replace! sp 11 11 " 2")
    (faces-become sp '(("car" function.builtin) ("2" number)))))
