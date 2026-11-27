#!tuna
(import (options) (ask))

(options:set! ask:y-or-n-reader (lambda (question) #t))
