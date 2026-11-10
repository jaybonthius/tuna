#!tuna
(on-unload (lambda () (display "first ")))
(on-unload (lambda () (error 'second "failed")))
(on-unload (lambda () (display "third ")))
