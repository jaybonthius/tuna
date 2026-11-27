#!tuna
(import (modes) (modes-test text))

(modes:define-minor-mode bad "Bad." (majors . modes-test/text:mode))
