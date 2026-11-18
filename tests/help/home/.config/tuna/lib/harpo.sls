#!tuna
(import (commands) (keys) (modes))

(commands:define-command (honk)
  "Honks once."
  (void))

(commands:define-command (quiet)
  "Does nothing, on no key."
  (void))

(define-option volume 3 fixnum? "How loud a honk is.")

(define-hook after-honk "Called after each honk.")

(define-table horns "Maps a horn's name to its sound.")

(define-saved honks 0 fixnum?)

(define (squeeze n) "Squeezes the horn N times." n)

(define pitch 440)

(define-syntax with-horn
  (syntax-rules () [(_ body ...) (begin body ...)]))

(define-table keymap "Harpo's keys.")

(define-hook mode-hook "Called in each Harpo buffer.")

(modes:define-major-mode mode (lighter "Harpo") (keymap keymap) (hook mode-hook))

(define-table minor-keymap "Keys of the horn mode.")

(define (horn-mode?) "Whether the horn is out." #t)

(keys:bind! keymap "C-c h" honk)
(keys:bind! minor-keymap "C-c q" quiet)
(table-set! commands:command-modes honk (list mode))
(table-set! commands:command-modes quiet '())
