(import (tuna) (tuna plugins))
(define recent-commands '())

(use-plugin commands
  (config
    (add-hook! commands:after-command
      (lambda (command) (set! recent-commands (cons command recent-commands))))))

(commands:define-command (open-notes) "Opens the notes." 'notes)

(define (recent-names) (map commands:command-name recent-commands))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(import (console))
