#!tuna
(import (hooks) (options) (tables))
(hooks:define-hook after-save "Called with the path of each file saved.")
(hooks:define-hook before-save)
(hooks:define-hook find-handlers)
(options:define-option autosave-seconds 0 real? "Seconds between autosaves; 0 for none.")
(tables:define-table modes)
(define-record-type entry (fields path))

(define (save! path)
  "Saves the file at a path."
  (before-save path)
  (after-save path)
  path)
