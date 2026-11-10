(library (tuna lang)
  (export language)
  (import (chezscheme) (chez-lang reader) (chez-lang language))

  (define language
    (make-s-exp-language default-readtable (read-mode chez)
      '((chezscheme) (tuna) (only (tuna core modules) tuna-module-body))
      'tuna-module-body)))
