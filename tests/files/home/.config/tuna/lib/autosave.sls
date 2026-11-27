#!tuna
(import (buffers) (files) (timers))

(define (save-modified)
  (for-each (lambda (buffer)
              (when (buffers:modified? buffer)
                (guard (c [(or (files:changed-on-disk-condition? c) (files:canceled-condition? c)) #f])
                  (files:save-buffer buffer))))
            (files:buffers)))

(timers:run-when-idle 5 save-modified)
