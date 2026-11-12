(import (tuna) (tuna plugins))
(use-plugin nothere (local "~/src/nothere")
  (config
    (display "[nothere config]\n")))
(use-plugin dict (git "https://github.com/bob/dict") (commit "0000000")
  (config
    (display "[dict config]\n")))
(use-plugin broken
  (config
    (set-option! broken:level 3)
    (display "[broken config]\n")))
(use-plugin spell
  (config
    (set-option! spell:language 42)
    (display "[second form]\n")
    (let ((x)) x)
    (spell:check)
    (raise (make-error))
    (display "[last form]\n")))
(display (list 'after (spell:language)))
(newline)
(import (console))
