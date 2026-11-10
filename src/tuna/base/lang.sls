(library (tuna base lang)
  (export language)
  (import (chezscheme) (chez-lang reader) (chez-lang language))

  (define language
    (make-s-exp-language default-readtable (read-mode chez)
      '((tuna base) (only (tuna core modules) tuna-module-body))
      'tuna-module-body)))
