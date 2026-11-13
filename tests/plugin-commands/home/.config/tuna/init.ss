(import (tuna) (tuna plugins))
(use-plugin spell (git "https://github.com/bob/spell") (commit "8f4a734"))
(use-plugin files)
(use-plugin fill)
(use-plugin prog)

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

(when-installed (vertico)
  (set-option! vertico:count 15))
(use-plugin sources (git "https://github.com/groucho/tuna-sources"))
(use-plugin compat)
(use-plugin consult)
(use-plugin embark)
(use-plugin embark-consult)
(import (console))
