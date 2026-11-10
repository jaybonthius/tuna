(import (tuna))
(import (spell) (files) (fill) (prog) (greet))

(set-option! spell:language "en-GB"
             fill:column 80
             files:autosave-seconds 30)

(set! spell:dictionary-path (lambda () "/home/groucho/words"))

(define (announce save! path)
  (display (string-append "saving " path))
  (save! path))
(advice-add! files:save! announce)

(remove-hook! files:after-save spell:check)

(add-hook! prog:mode-hook
  (lambda ()
    (set-option-local! fill:column 100)
    (add-local-hook! files:before-save prog:indent-buffer -10)))
