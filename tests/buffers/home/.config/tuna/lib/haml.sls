;; Stands in for the HTML library, which this configuration lacks: a
;; node's drawing is the list of its tag and children.
(library (haml)
  (export haml)
  (import (chezscheme))

  (define-syntax haml
    (syntax-rules ()
      [(_ (tag child ...)) (list 'tag child ...)])))
