#!tuna
(import (modes) (modes-test text))

(modes:define-minor-mode bad "Bad." (state (b) #t))
