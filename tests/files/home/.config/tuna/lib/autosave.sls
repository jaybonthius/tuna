#!tuna
(import (files))

(define (save-modified)
  (for-each (lambda (buffer)
              (when (files:modified? buffer)
                (guard (c [(files:changed-on-disk-condition? c) #f])
                  (files:save-buffer buffer))))
            (files:buffers)))

(run-with-idle-timer 5 save-modified)
