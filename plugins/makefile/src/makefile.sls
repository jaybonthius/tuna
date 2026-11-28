#!tuna
(import (languages) (modes) (prog) (indentation) (editing) (hooks) (options) (tables))

(tables:define-table keymap "Keys in Makefile buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on makefile:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Makefile")
  (keymap keymap)
  (hook mode-hook))

(languages:define-grammar make
  (git "https://github.com/tree-sitter-grammars/tree-sitter-make" "70613f3d812cbabbd7f38d104d60a409c4008b43"))

(languages:define-language "makefile"
  (mode mode)
  (file-names "Makefile" "makefile" "GNUmakefile" "mk" "mak" "make")
  (interpreters "make" "gmake")
  (grammar make)
  (line-comments ("#"))
  (strings ("\"" "\"" (escape #\\) line-bound) ("'" "'" line-bound))
  (brackets ("(" ")") ("{" "}")))

;; A recipe line must start with a tab, which no rule of indentation
;; computes, so the indenter leaves every line as it is: RET then starts
;; the new line at column 0 and TAB, changing nothing, inserts a tab
;; through the fallback, as Emacs's makefile-mode does with
;; indent-to-left-margin.
(define (indenter buffer start) #f)

(tables:set! indentation:indenters mode indenter)
(hooks:add! mode-hook
  (lambda ()
    (options:set-local! indentation:use-tabs? #t)
    (options:set-local! editing:tab-fallback editing:insert-tab)))
