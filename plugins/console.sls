#!tuna
(import (tuna eval) (console input))

;; The console offers no names, and a form that unloads the console still
;; prints its values, so nothing here is a changeable definition.
(let ()
  (define (show . values)
    (let ([out (current-output-port)])
      (for-each
        (lambda (v)
          (unless (eq? v (void))
            (fresh-line out)
            (write v out)
            (newline out)))
        values)
      (fresh-line out)
      (flush-output-port out)))

  ;; Unloading the console quits the task waiting for input, which has
  ;; nothing to report; any other quit is reported as in any task.
  (define (evaluate-next)
    (as-module '(repl)
      (let ([text (guard (c [(and (quit-condition? c) (not on?)) #f]) (read-form-text))])
        (cond
          [(eof-object? text) (exit)]
          [text (call-with-values (lambda () (eval-text text)) show)]))))

  (define on? #t)

  (on-unload (lambda () (set! on? #f)))

  ;; A task per form reports a raise as any task does and ends only that
  ;; form; joining it makes the next read wait for the form's end, pauses
  ;; included. What join-task raises again was reported already.
  (spawn-task
    (lambda ()
      (let loop ()
        (guard (c [#t #f])
          (join-task (spawn-task evaluate-next)))
        (when on? (loop))))))
