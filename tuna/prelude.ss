;;; The language for Tuna packages (ADR 1): Gerbil core plus the
;;; plugin declaration. Editor forms come from explicit contract imports.
;;; Use it as `#lang :tuna/prelude`; that also compiles
;;; the module with (declare (separate)), so `set!` from a REPL or init.ss
;;; reaches the module's own calls.
prelude: :gerbil/core

(import :gerbil/core
        :tuna/kernel)
(export (import: :gerbil/core)
        defplugin
        (phi: +1 read-module-body))

(begin-syntax
  (def (read-module-body port)
    (let lp ((body []))
      (let (next (read-syntax port))
        (if (eof-object? next)
          (cons '(declare (separate)) (reverse body))
          (lp (cons next body)))))))
