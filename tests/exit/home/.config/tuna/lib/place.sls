#!tuna
(import (keeper))
(on-unload
  (lambda ()
    (display (if (current-task) "unloading in a task" "unloading outside any task"))
    (newline)))
