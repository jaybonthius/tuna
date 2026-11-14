(library (tuna base lang)
  (export language)
  (import (chezscheme) (lang reader) (lang language))

  (define language
    (make-s-exp-language default-readtable (read-mode chez)
      '((chezscheme) (tuna base) (only (tuna core modules) tuna-module-body))
      'tuna-module-body)))
