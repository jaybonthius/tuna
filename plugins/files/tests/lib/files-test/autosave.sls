#!tuna
(import (buffers) (files) (timers))

(define (save-modified)
  (let-values ([(reloaded stale) (files:revert-changed-buffers buffers:modified?)])
    (for-each (lambda (buffer)
                (when (and (buffers:modified? buffer) (not (memq buffer stale)))
                  (guard (c [(files:canceled-condition? c) #f])
                    (files:save-buffer buffer))))
              (files:buffers))))

(timers:run-when-idle 5 save-modified)
