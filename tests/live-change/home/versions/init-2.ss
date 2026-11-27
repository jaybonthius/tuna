(import (tuna) (plugins))
(import (spell) (files))

(define spell:dictionary-path (lambda () "/home/groucho/other-words"))
(on-unload (lambda () (display "configuration unloading")))
