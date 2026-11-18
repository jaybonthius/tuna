#!tuna
(import (ask))

;; The reader ends its question on any raise, as on a quit, so the time
;; running out is a raise in the asking task.
(define %no-answer (make-message-condition "no answer"))

(define (%question c)
  (format "~a; exit anyway? " (call-with-string-output-port (lambda (p) (display-condition c p)))))

;; A question that cannot be asked, as when no reader is loaded, gets no
;; answer, so Tuna exits; a quit, as from C-g, goes on and Tuna stays, as
;; in Emacs. Waiting for the answer pauses the task, which runs its
;; after-thunks, so the timer is not cancelled in one; after a quit it
;; fires at a task that has ended, which does nothing.
(define (%ask-to-exit exit-anyway? c)
  (and (exit-anyway? c)
       (as-module (this-module)
         (let* ([task (current-task)]
                [timer (run-with-timer 5 (lambda () (signal-task task %no-answer)))]
                [answer (guard (e [(eq? e %no-answer) #t]
                                  [(not (quit-condition? e)) (report e) #t])
                          (ask:y-or-n? (%question c)))])
           (cancel-timer! timer)
           answer))))

(advice-add! exit-anyway? %ask-to-exit)
