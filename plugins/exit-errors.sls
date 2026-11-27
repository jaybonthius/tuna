#!tuna
(import (ask) (timers))

(define %self (current-owner))

;; The reader ends its question on any raise, as on a cancel, so the time
;; running out cancels the asking task, with this reason.
(define %no-answer (list 'no-answer))

(define (%question c)
  (format "~a; exit anyway? " (call-with-string-output-port (lambda (p) (display-condition c p)))))

;; A question that cannot be asked, as when no reader is loaded, gets no
;; answer, so Tuna exits; a quit, as from C-g, goes on and Tuna stays, as
;; in Emacs. Waiting for the answer pauses the task, which runs its
;; after-thunks, so the timer is not cancelled in one; after a quit it
;; fires at a task that has ended, which does nothing.
(define (%ask-to-exit exit-anyway? c)
  (and (exit-anyway? c)
       (call-as-owner %self
         (lambda ()
           (let* ([task (current-task)]
                  [timer (timers:run-after 5 (lambda () (cancel-task task %no-answer)))]
                  [answer (guard (e [(and (cancelled? e) (eq? (cancelled-reason e) %no-answer)) #t]
                                    [(not (cancelled? e)) (report e) #t])
                            (ask:y-or-n? (%question c)))])
             (timers:cancel! timer)
             answer)))))

(advice-add! exit-anyway? %ask-to-exit)
