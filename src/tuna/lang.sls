(library (tuna lang)
  (export language)
  (import (chezscheme) (lang reader) (lang language))

  (define language
    (make-s-exp-language default-readtable (read-mode chez)
      '((chezscheme) (tuna) (only (tuna modules) tuna-module-body))
      'tuna-module-body)))
