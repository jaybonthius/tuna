#!tuna
(define-hook after-save "Called with the path of each file saved.")
(define-hook before-save)
(define-hook find-handlers)
(define-option autosave-seconds 0 real? "Seconds between autosaves; 0 for none.")

(define (save! path)
  "Saves the file at a path."
  (before-save path)
  (after-save path)
  path)
