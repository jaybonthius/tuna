(library (tuna documentation)
  (export documentation)
  (import (chezscheme) (only (tuna core definitions) changeable-procedure-documentation)
          (only (tuna hooks) hook? hook-documentation)
          (only (tuna options) option? option-documentation)
          (only (tuna tables) table? table-documentation))

  (define (documentation v)
    (cond
      [(hook? v) (hook-documentation v)]
      [(option? v) (option-documentation v)]
      [(table? v) (table-documentation v)]
      [(procedure? v) (changeable-procedure-documentation v)]
      [else #f])))
