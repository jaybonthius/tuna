(import (hooks) (options) (tables) (timers) (scopes) (plugins))
(import (tuna))
(use-plugin spell (git "https://github.com/bob/spell") (commit "3fd4dae"))
(use-plugin files)
(use-plugin fill)
(use-plugin prog)

(options:set! spell:language "en-GB"
             fill:column 80
             files:autosave-seconds 30)

(define spell:dictionary-path (lambda () "/home/groucho/words"))

(define (announce save! path)
  (display (string-append "saving " path))
  (save! path))
(advice-add! files:save! announce)

(hooks:remove! files:after-save spell:check)

(hooks:add! prog:mode-hook
  (lambda ()
    (options:set-local! fill:column 100)
    (hooks:add-local! files:before-save prog:indent-buffer -10)))

(import (console))
