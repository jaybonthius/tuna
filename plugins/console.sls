#!tuna
(import (console input) (plugins))

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

  (define (evaluate text)
    (let ([p (open-input-string text)])
      (let loop ([results (list (void))])
        (let ([form (read p)])
          (if (eof-object? form)
              (apply values results)
              (loop (call-with-values (lambda () (plugins:eval-form form)) list)))))))

  (define (evaluate-next)
    (call-as-owner (plugins:repl-owner)
      (lambda ()
        (let ([text (read-form-text)])
          (if (eof-object? text)
              (exit)
              (call-with-values (lambda () (evaluate text)) show))))))

  ;; A task per form reports a raise as any task does and ends only that
  ;; form; joining it makes the next read wait for the form's end, pauses
  ;; included.
  (spawn-task
    (lambda (restore)
      (let loop ()
        (join-task (spawn-task (lambda (restore) (evaluate-next))))
        (loop)))))
