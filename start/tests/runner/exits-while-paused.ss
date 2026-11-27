(import (tuna))

(spawn-task (lambda (restore) (exit)))
(suspend (lambda (resume) (void)))
