#!tuna
(import (exit log) (exit keeper))
(on-unload (lambda () (exit/log:note! (if (current-task) "unloading in a task" "unloading outside any task"))))
