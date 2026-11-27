#!tuna
(import (completion) (minibuffer) (keys) (commands) (views) (layout) (editing) (kill-ring) (web) (ask)
        (buffers) (browse-url) (hooks) (options) (tables))

(options:define-option quit-after-action? #t boolean?
  "Whether an action quits the read whose candidate it acts on; C-u before C-. or C-; reverses it once.")

(tables:define-table default-actions
  "Maps a category to the command actions:act-default runs on a target of that category, in place of choosing a read's target as RET does, or of the RET binding of the target's keymaps.")

(tables:define-table general-keymap "The actions on every target, searched after the target's category's keymaps.")

(define (%read-session)
  (let ([s (completion:current-session)])
    (and s (completion:session-prompt s) s)))

;; With empty input the read answers with its default, so the default is
;; what an action acts on.
(define (%read-target who s)
  (let ([m (completion:selected s)] [categories (completion:session-categories s)])
    (cond
      [m (completion:make-target (completion:category s m) (completion:value s m) (completion:whole-text s m) #f #f)]
      [(and (pair? categories) (for-all (lambda (c) (eq? c (car categories))) categories))
       (let* ([input (minibuffer:input (completion:session-prompt s))]
              [text (or (and (string=? input "") (completion:session-default s)) input)])
         (completion:make-target (car categories) text text #f #f))]
      [else (error who "No target found")])))

;; The region is what the user marked, not a reading of the text, so it
;; hides no later target of the same bounds; any other target hides a
;; later one, since an earlier finder read the same text more closely.
(define (%found-targets view)
  (let loop ([entries (hooks:entries completion:target-finders)] [kept '()])
    (if (null? entries)
        (reverse kept)
        (let ([t ((car entries) view)])
          (cond
            [(not t) (loop (cdr entries) kept)]
            [(not (completion:target? t))
             (assertion-violation 'actions:act "a target finder returned what is neither a target nor #f" t)]
            [(and (completion:target-start t)
                  (exists (lambda (k)
                            (and (not (eq? (completion:target-category k) completion:region-category))
                                 (eqv? (completion:target-start k) (completion:target-start t))
                                 (eqv? (completion:target-end k) (completion:target-end t))))
                          kept))
             (loop (cdr entries) kept)]
            [else (loop (cdr entries) (cons t kept))])))))

;; A session at point is not a read, but its selected row is the target
;; the user is looking at, as Embark's first finder takes the
;; *Completions* candidate.
(define (%point-targets who view)
  (let* ([s (completion:current-session)]
         [m (and s (completion:selected s))]
         [found (%found-targets view)]
         [all (if m
                  (cons (completion:make-target (completion:category s m) (completion:value s m)
                                                (completion:whole-text s m) #f #f)
                        found)
                  found)])
    (when (null? all)
      (error who "No target found"))
    (values all (and m s))))

(define (%nth targets n)
  (list-ref targets (mod n (length targets))))

(define (%keymaps category)
  (append (or (and category (tables:ref completion:action-keymaps category #f)) '())
          (list general-keymap)))

(define (%quit?)
  (if (commands:prefix-argument) (not (quit-after-action?)) (quit-after-action?)))

(define (%prefix-command? v)
  (and (memq v (list keys:universal-argument keys:digit-argument keys:negative-argument)) #t))

(define (%make-quit) (make-cancelled #f))

;; A read returns quit keys as data, so one cancels here, and says so, as
;; a quit key does outside a read. Once a prefix argument is begun, a digit
;; goes on typing it even where the keymaps bind the digit, as after C-u.
;; Before the first key the client's own keymaps give C-u, M-<digit> and
;; M--, which the target's keymaps do not bind.
(define (read-action keymaps text)
  (unless (and (list? keymaps) (for-all tables:table? keymaps))
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
               [(tables:table? found) (loop prefix begun? sequence)]
               [else (errorf 'actions:read-action "~a is not an action" sequence)]))])))))

(define (%check-read who s)
  (unless (eq? (minibuffer:current-prompt) (completion:session-prompt s))
    (error who "The read has ended")))

(define (%call command prefix)
  (parameterize ([commands:prefix-argument prefix])
    (commands:run command)))

;; The cursors are kept as anchors, which follow every edit however long
;; the command pauses. They come back when the command returns or raises,
;; not at each pause, as an after-thunk of dynamic-wind would: a command
;; that asks first, such as M-|, must find the target as its region once
;; the answer comes.
(define (%call-on-region view target thunk)
  (let* ([b (views:buffer view)]
         [saved (map (lambda (c)
                       (let ([m (views:cursor-mark c)])
                         (cons (buffers:anchor b (views:cursor-point c)) (and m (buffers:anchor b m)))))
                     (views:cursors view))])
    (define (position a) (and a (buffers:anchor-position a)))
    (define (restore!)
      (when (eq? (views:buffer view) b)
        (for-each (lambda (c) (views:remove-cursor! view c)) (cdr (views:cursors view)))
        (views:set-cursor! (car (views:cursors view)) (position (caar saved)) (position (cdar saved)))
        (for-each (lambda (spots)
                    (let ([c (views:add-cursor! view (position (car spots)))])
                      (views:set-cursor! c (position (car spots)) (position (cdr spots)))))
                  (cdr saved))))
    (for-each (lambda (c) (views:remove-cursor! view c)) (cdr (views:cursors view)))
    (views:set-cursor! (car (views:cursors view)) (completion:target-start target) (completion:target-end target))
    ;; A warning matches no clause, so guard raises it again as continuable
    ;; where it was raised and the command goes on after the report.
    (guard (c [(not (warning? c)) (restore!) (raise c)])
      (thunk))
    (restore!)))

;; A command marked as acting on the region asks only for what else it
;; needs, so the target goes in as the region, never as an answer: C-. |
;; on a region leaves the shell line to the user. Every other command's
;; first prompt is answered with the target, not with RET, which takes
;; whatever its read selects.
(define (%run-action! command target prefix view)
  (views:call-with-view view
    (lambda ()
      (cond
        [(not (tables:ref commands:region-commands command #f))
         (minibuffer:call-with-setup
           (lambda (p) (completion:answer-target! p target))
           (lambda () (%call command prefix)))]
        [(completion:target-start target)
         (%call-on-region view target (lambda () (%call command prefix)))]
        [else (%call command prefix)]))))

;; A kept read's action runs with the view the read was started from
;; selected, since commands such as layout:switch-to-buffer act on the
;; selected view, and the read gets the selection back.
(define (%act-on-read! who s target command prefix quit?)
  (%check-read who s)
  (let* ([prompt (completion:session-prompt s)] [back (layout:selected-view)]
         [view (or (minibuffer:prompt-selected-view prompt) back)])
    (define (reselect!)
      (when (and (eq? (minibuffer:current-prompt) prompt) (or (layout:view-node back) (layout:popup-node back)))
        (layout:select! back)))
    (cond
      [quit? (minibuffer:abort) (%run-action! command target prefix view)]
      [else
       (layout:select! view)
       (guard (c [(not (warning? c)) (reselect!) (raise c)])
         (%run-action! command target prefix view))
       (reselect!)])))

(define (%default-entry target)
  (let ([category (completion:target-category target)])
    (and category (tables:ref default-actions category #f))))

(define (%act-default-on-read! who s target prefix quit?)
  (let ([command (%default-entry target)])
    (cond
      [command (%act-on-read! who s target command prefix quit?)]
      [else
       (%check-read who s)
       (completion:exit)])))

(define (%act-at-point! target row-session command prefix)
  (when row-session (completion:end! row-session))
  (%run-action! command target prefix (views:current)))

;; A popup row's own default is choosing it, as the popup's RET does.
(define (%act-default-at-point! who target row? row-session prefix)
  (let ([entry (%default-entry target)])
    (cond
      [(and row? (not entry)) (completion:exit)]
      [(or entry (let ([found (keys:lookup-in (%keymaps (completion:target-category target)) "RET")])
                   (and (commands:command? found) found)))
       => (lambda (command) (%act-at-point! target row-session command prefix))]
      [else (errorf who "No default action for ~a" (completion:target-text target))])))

;; C-. while an action is read moves to the next target, as Embark's
;; cycle key is embark-act's own; a prefix typed before it moves that
;; many.
(define (%choose-action targets first)
  (let loop ([i first])
    (let ([t (%nth targets i)])
      (let-values ([(command prefix) (read-action (%keymaps (completion:target-category t)) (completion:target-text t))])
        (if (eq? command act)
            (loop (fx+ i (parameterize ([commands:prefix-argument prefix]) (commands:prefix-number))))
            (values t command prefix))))))

(commands:define-command (act)
  "Reads an action on the target with actions:read-action, in its category's keymaps and then actions:general-keymap, and runs it; RET runs the default action, as actions:act-default does, and C-. moves to the next target. In a read the target is its selected candidate or, with none, its input, or its default when the input is empty, when its sources share a category, and the action quits the read first as actions:quit-after-action? says. Elsewhere the targets are the selected row of a session at point, then those of completion:target-finders, and a numeric argument starts that many targets further on."
  (let ([s (%read-session)])
    (if s
        (let ([quit? (%quit?)])
          (let-values ([(t command prefix) (%choose-action (list (%read-target 'actions:act s)) 0)])
            (if (eq? command act-default)
                (%act-default-on-read! 'actions:act s t prefix quit?)
                (%act-on-read! 'actions:act s t command prefix quit?))))
        (let-values ([(targets row-session) (%point-targets 'actions:act (views:current))])
          (let-values ([(t command prefix)
                        (%choose-action targets (if (commands:prefix-argument) (commands:prefix-number) 0))])
            (if (eq? command act-default)
                (%act-default-at-point! 'actions:act t (and row-session (eq? t (car targets))) row-session prefix)
                (%act-at-point! t row-session command prefix)))))))

(commands:define-command (act-default)
  "Runs the default action on the target, as actions:act runs an action: the command actions:default-actions maps its category to, else, in a read, choosing it as RET does, and elsewhere the RET binding of its keymaps, or choosing a popup row. With a numeric argument outside a read, the target that many further on."
  (let ([s (%read-session)])
    (if s
        (%act-default-on-read! 'actions:act-default s (%read-target 'actions:act-default s) #f (%quit?))
        (let-values ([(targets row-session) (%point-targets 'actions:act-default (views:current))])
          (let ([t (%nth targets (if (commands:prefix-argument) (commands:prefix-number) 0))])
            (%act-default-at-point! 'actions:act-default t (and row-session (eq? t (car targets))) row-session #f))))))

(commands:define-command (insert [text (ask:line "Insert: ")])
  "Inserts TEXT at each cursor of the current view, as editing:insert! does."
  (editing:insert! (views:current) text))

(commands:define-command (copy [text (ask:line "Copy: ")])
  "Pushes TEXT on the kill ring."
  (kill-ring:push! (list text)))

(keys:bind! keys:global "C-." act)
(keys:bind! keys:global "C-;" act-default)
(keys:bind! general-keymap "C-." act)
(keys:bind! general-keymap "i" insert)
(keys:bind! general-keymap "w" copy)
(keys:bind! general-keymap "-" keys:negative-argument)
(for-each (lambda (d) (keys:bind! general-keymap d keys:digit-argument)) '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(keys:bind! completion:url-action-keymap "RET" browse-url:open)
(keys:bind! completion:region-action-keymap "u" editing:upcase-region)
(keys:bind! completion:region-action-keymap "l" editing:downcase-region)
(keys:bind! completion:region-action-keymap "c" editing:capitalize-region)
(keys:bind! completion:expression-action-keymap "k" editing:kill-region)
