(import (tuna))
(import (spell) (files))
(set! spell:dictionary-path (lambda () "/home/groucho/words"))

(define (announce save! path)
  (display (string-append "saving " path))
  (save! path))
(advice-add! files:save! announce)
(import (console))
