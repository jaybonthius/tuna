#!tuna
(import (test-runner) (layout) (keys) (commands) (hooks) (tables) (test-user))

(define (raised-by who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (on-thread thunk)
  (let ([result #f])
    (join-task
      (fork-task
        (lambda (restore)
          (set! result
            (guard (c [(and (who-condition? c) (message-condition? c)) (list (condition-who c) (condition-message c))])
              (thunk))))))
    result))

(define (report-messages thunk)
  (map (lambda (c) (if (message-condition? c) (condition-message c) c)) (test-runner:reports-during thunk)))

(tables:define-table capture-keymap "Catches the click that posn-at makes.")

(define %captured #f)

(commands:define-command (capture [event (keys:command-event)])
  "Keeps the event that ran it."
  (set! %captured event))

;; Entries of keys:find-keymaps read a posn through views, so a test that
;; needs one gets a real one from a click in the selected view.
(define (posn-at at)
  (let ([entry (lambda (client posn) (if posn (list capture-keymap) '()))])
    (hooks:add! keys:find-keymaps entry -200)
    (set! %captured #f)
    (test-user:settle)
    (test-user:click! (layout:selected-view) at "s-<mouse-9>")
    (hooks:remove! keys:find-keymaps entry)
    (unless %captured
      (assertion-violation 'keys-test:posn-at "the click ran no command" at))
    (keys:event-start %captured)))

(keys:bind! capture-keymap "s-<mouse-9>" capture)
