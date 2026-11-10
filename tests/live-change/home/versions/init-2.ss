(import (tuna) (tuna eval))
(import (spell) (files))

(set! spell:dictionary-path (lambda () "/home/groucho/other-words"))
(on-unload (lambda () (display "configuration unloading")))
