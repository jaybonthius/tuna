#!tuna
(import (exit log))
(on-unload (lambda () (exit/log:note! "keeper unloading")))
