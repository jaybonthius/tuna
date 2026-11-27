(import (hooks) (options) (tables) (timers) (scopes) (plugins))
(import (tuna))
(import (spell) (files) (fill) (prog))

;; Chez judges an object stale by file times, which the file system keeps
;; to its clock tick, so a source written in the tick its object was
;; compiled in would count as compiled.
(define (put-version! version path)
  (timers:sleep 0.01)
  (let* ([home (getenv "HOME")] [file (string-append home "/" path)])
    (let ([text (call-with-input-file (string-append home "/versions/" version) get-string-all)])
      ;; git keeps no empty folder, so lib/ is made by the first module put there.
      (unless (file-exists? (path-parent file))
        (mkdir (path-parent file)))
      (with-output-to-file file
        (lambda () (put-string (current-output-port) text))
        'replace))))

(options:set! spell:language "en-GB"
             fill:column 80
             files:autosave-seconds 30)

(define spell:dictionary-path (lambda () "/home/groucho/words"))

(hooks:remove! files:after-save spell:check)

(hooks:add! prog:mode-hook
  (lambda ()
    (options:set-local! fill:column 100)
    (hooks:add-local! files:before-save prog:indent-buffer -10)))
(import (console))
