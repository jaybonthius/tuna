#!tuna
(import (web) (views) (buffers) (layout) (keys) (commands) (hooks) (tables) (test-user))

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

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (report-messages thunk)
  (map (lambda (c) (if (message-condition? c) (condition-message c) c)) (reports-during thunk)))

;; A mouse item as views' page script sends one for the selected view, so
;; the event keys gets carries a posn of views' own making.
(define (mouse-item action button clicks modifiers at)
  (let* ([v (layout:selected-view)] [b (views:buffer v)])
    (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" clicks)
          (cons "modifiers" (list->vector modifiers)) (cons "view" (views:id v))
          (cons "showing" (views:shown-count v)) (cons "version" (buffers:version b)) (cons "at" at) (cons "report" 0))))

(define (mouse! action button clicks modifiers at)
  (web:post-input! (test-user:client) (mouse-item action button clicks modifiers at))
  (test-user:settle))

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
    (mouse! "click" 9 1 '("super") at)
    (hooks:remove! keys:find-keymaps entry)
    (unless %captured
      (assertion-violation 'keys-test:posn-at "the click ran no command" at))
    (keys:event-start %captured)))

(keys:bind! capture-keymap "s-<mouse-9>" capture)
