(import (tuna) (tuna eval))
(import (spell) (files))

;; Chez judges an object stale by file times, which the file system keeps
;; to its clock tick, so a source written in the tick its object was
;; compiled in would count as compiled.
(define (put-version! version path)
  (sleep-for 0.01)
  (let* ([home (getenv "HOME")] [file (string-append home "/" path)])
    (let ([text (call-with-input-file (string-append home "/versions/" version) get-string-all)])
      ;; git keeps no empty folder, so lib/ is made by the first module put there.
      (unless (file-exists? (path-parent file))
        (mkdir (path-parent file)))
      (with-output-to-file file
        (lambda () (put-string (current-output-port) text))
        'replace))))

(set! spell:dictionary-path (lambda () "/home/groucho/words"))

(define (announce save! path)
  (display (string-append "saving " path " "))
  (save! path))
(advice-add! files:save! announce)
(import (console))
