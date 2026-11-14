#!tuna
(import (buffers) (files))

(define (save-modified)
  (for-each (lambda (buffer)
              (when (buffers:modified? buffer)
                (guard (c [(files:changed-on-disk-condition? c) #f])
                  (files:save-buffer buffer))))
            (files:buffers)))

(run-with-idle-timer 5 save-modified)
