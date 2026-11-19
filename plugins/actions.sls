#!tuna
(import (completion) (minibuffer) (keys) (commands) (views) (layout) (editing) (kill-ring) (web) (ask))

(define-option quit-after-action? #t boolean?
  "Whether an action quits the read whose candidate it acts on; C-u before C-. or C-; reverses it once.")

(define-table default-actions
  "Maps a category to the command actions:act-default runs on a read's target of that category, in place of choosing it as RET does.")

(define-table general-keymap "The actions on every target, searched after the target's category's keymaps.")

;; With empty input the read answers with its default, so the default is
;; what an action acts on.
(define (%target who)
  (let ([s (completion:current-session)])
    (unless (and s (completion:session-prompt s))
      (error who "No target found"))
    (let ([m (completion:selected s)] [categories (completion:session-categories s)])
      (cond
        [m (values s (completion:category s m) (completion:whole-text s m))]
        [(and (pair? categories) (for-all (lambda (c) (eq? c (car categories))) categories))
         (let ([input (minibuffer:input (completion:session-prompt s))])
           (values s (car categories)
                   (or (and (string=? input "") (completion:session-default s)) input)))]
        [else (error who "No target found")]))))

(define (%keymaps category)
  (append (or (and category (table-ref completion:action-keymaps category #f)) '())
          (list general-keymap)))

(define (%quit?)
  (if (commands:prefix-argument) (not (quit-after-action?)) (quit-after-action?)))

(define (%prefix-command? v)
  (and (memq v (list keys:universal-argument keys:digit-argument keys:negative-argument)) #t))

(define %make-quit (record-constructor (record-constructor-descriptor &quit)))

;; A read returns quit keys as data, so one cancels here, and says so, as
;; a quit key does outside a read. Once a prefix argument is begun, a digit
;; goes on typing it even where the keymaps bind the digit, as after C-u.
;; Before the first key the client's own keymaps give C-u, M-<digit> and
;; M--, which the target's keymaps do not bind.
(define (read-action keymaps text)
  (unless (and (list? keymaps) (for-all table? keymaps))
    (assertion-violation 'actions:read-action "not a list of keymaps" keymaps))
  (unless (string? text)
    (assertion-violation 'actions:read-action "not a string" text))
  (let ([client (web:current-client)] [question (string-append "Act on " text ": ")])
    (let loop ([prefix #f] [begun? #f] [typed #f])
      (let* ([key (keys:read-key question)] [name (and (string? key) key)])
        (cond
          [(not name) (errorf 'actions:read-action "~a is not an action" (keys:event-key key))]
          [(member name (keys:quit-keys))
           (ask:message "Quit")
           (raise (%make-quit))]
          [(and (not typed) (string=? name "RET")) (values act-default prefix)]
          [else
           (let* ([sequence (if typed (string-append typed " " name) name)]
                  [found (keys:lookup-in (if (and begun? (not typed)) (cons keys:universal-argument-keymap keymaps) keymaps)
                                         sequence)]
                  [prefix-command (find %prefix-command? (list found (and (not found) (not typed) (keys:lookup client name))))])
             (cond
               [prefix-command (loop (keys:prefix-after prefix-command sequence prefix) #t #f)]
               [(commands:command? found) (values (or (keys:command-remapping client found) found) prefix)]
               [(table? found) (loop prefix begun? sequence)]
               [else (errorf 'actions:read-action "~a is not an action" sequence)]))])))))

(define (%check-read who s)
  (unless (eq? (minibuffer:current-prompt) (completion:session-prompt s))
    (error who "The read has ended")))

;; The command's first prompt is answered with the target's text as if
;; typed, not with RET, which takes whatever its read selects: another
;; candidate may rank first for that text. A kept read's action runs with
;; the view the read was started from selected, since commands such as
;; layout:switch-to-buffer act on the selected view, and the read gets the
;; selection back.
(define (%act! who s text command prefix quit?)
  (%check-read who s)
  (let* ([prompt (completion:session-prompt s)] [back (layout:selected-view)]
         [view (or (minibuffer:prompt-selected-view prompt) back)])
    (define (run)
      (views:call-with-view view
        (lambda ()
          (parameterize ([commands:prefix-argument prefix])
            (minibuffer:call-with-setup
              (lambda (p)
                (minibuffer:set-input! p text)
                (completion:answer-input! p))
              (lambda () (commands:run command)))))))
    (define (reselect!)
      (when (and (eq? (minibuffer:current-prompt) prompt) (or (layout:view-node back) (layout:popup-node back)))
        (layout:select! back)))
    (cond
      [quit? (minibuffer:abort) (run)]
      [else
       (layout:select! view)
       ;; A warning matches no clause, so guard raises it again as continuable
       ;; where it was raised and the command goes on after the report.
       (guard (c [(not (warning? c)) (reselect!) (raise c)])
         (run))
       (reselect!)])))

(define (%act-default! who s category text prefix quit?)
  (let ([command (and category (table-ref default-actions category #f))])
    (cond
      [command (%act! who s text command prefix quit?)]
      [else
       (%check-read who s)
       (completion:exit)])))

(commands:define-command (act)
  "Reads an action on the target with actions:read-action, in its category's keymaps and then actions:general-keymap, and runs it, quitting the read first as actions:quit-after-action? says; RET runs the default action, as actions:act-default does. The target is the read's selected candidate or, with none, its input, or its default when the input is empty, when its sources share a category."
  (let-values ([(s category text) (%target 'actions:act)])
    (let ([quit? (%quit?)])
      (let-values ([(command prefix) (read-action (%keymaps category) text)])
        (if (eq? command act-default)
            (%act-default! 'actions:act s category text prefix quit?)
            (%act! 'actions:act s text command prefix quit?))))))

(commands:define-command (act-default)
  "Runs the default action on the target, as actions:act runs an action: the command actions:default-actions maps its category to, else choosing it as RET does."
  (let-values ([(s category text) (%target 'actions:act-default)])
    (%act-default! 'actions:act-default s category text #f (%quit?))))

(commands:define-command (insert [text (ask:line "Insert: ")])
  "Inserts TEXT at each cursor of the current view, as editing:insert! does."
  (editing:insert! (views:current) text))

(commands:define-command (copy [text (ask:line "Copy: ")])
  "Pushes TEXT on the kill ring."
  (kill-ring:push! (list text)))

(keys:bind! keys:global "C-." act)
(keys:bind! keys:global "C-;" act-default)
(keys:bind! general-keymap "i" insert)
(keys:bind! general-keymap "w" copy)
(keys:bind! general-keymap "-" keys:negative-argument)
(for-each (lambda (d) (keys:bind! general-keymap d keys:digit-argument)) '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(table-set! commands:command-modes act (list minibuffer:mode))
(table-set! commands:command-modes act-default (list minibuffer:mode))
