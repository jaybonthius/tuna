(import (tuna) (tuna eval))
(import (spell) (files) (fill) (prog))

;; Chez judges an object stale by file times, which the file system keeps
;; to its clock tick, so a source written in the tick its object was
;; compiled in would count as compiled.
(define (put-version! version path)
  (sleep (make-time 'time-duration 10000000 0))
  (let* ([home (getenv "HOME")] [file (string-append home "/" path)])
    (let ([text (call-with-input-file (string-append home "/versions/" version) get-string-all)])
      ;; git keeps no empty folder, so lib/ is made by the first module put there.
      (unless (file-exists? (path-parent file))
        (mkdir (path-parent file)))
      (with-output-to-file file
        (lambda () (put-string (current-output-port) text))
        'replace))))

(set-option! spell:language "en-GB"
             fill:column 80
             files:autosave-seconds 30)

(set! spell:dictionary-path (lambda () "/home/groucho/words"))

(remove-hook! files:after-save spell:check)

(add-hook! prog:mode-hook
  (lambda ()
    (set-option-local! fill:column 100)
    (add-local-hook! files:before-save prog:indent-buffer -10)))
