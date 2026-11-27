#!tuna
(import (pi) (chat) (pi-chat) (pi-picker) (transient) (commands) (keys) (tables))

(define (%title)
  (let ([chat (pi-chat:current-chat)])
    (cond
      [(not chat) "Pi"]
      [(pi:chat-session-name chat) => (lambda (name) (string-append "Pi: " name))]
      [else (string-append "Pi in " (pi:chat-directory chat))])))

(transient:define-menu menu "The Pi chat's menu."
  (title %title))

(define (%with-state description state)
  (lambda ()
    (let ([chat (pi-chat:current-chat)])
      (if chat (string-append description " (" (state chat) ")") description))))

(define (%model-name chat)
  (let ([m (pi:chat-model chat)]) (if m (pi:model-name m) "none")))

(define (%thinking-level chat) (or (pi:chat-thinking-level chat) "none"))

(define (%auto-compaction chat) (if (pi:chat-auto-compaction? chat) "on" "off"))

(define (%thinking-shown)
  (if (chat:thinking-shown?) "Finished thinking (shown)" "Finished thinking (folded)"))

;; q is left out, since a user may bind it to close menus, as Emacs's
;; transient does.
(define %command-keys
  (string->list "abcdefghijklmnoprstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"))

(define (%commands-of source)
  (let ([chat (pi-chat:current-chat)])
    (list-sort (lambda (a b) (string<? (pi:slash-command-name a) (pi:slash-command-name b)))
               (filter (lambda (c) (eq? (pi:slash-command-source c) source)) (if chat (pi:chat-commands chat) '())))))

(define (%command-entries source)
  (lambda ()
    (let* ([commands (%commands-of source)]
           [shown (list-head commands (min (length commands) (length %command-keys)))])
      (map (lambda (command key)
             (transient:command (string key) (string-append "/" (pi:slash-command-name command))
                                pi-picker:run-command command))
           shown (list-head %command-keys (length shown))))))

(define (%kind-entry key description source submenu)
  (let ([n (length (%commands-of source))])
    (and (fx> n 0)
         (transient:staying-command key (string-append description " (" (number->string n) ")") %show-above submenu))))

(define (%kind-entries)
  (filter values
          (list (%kind-entry "s" "Skills" 'skill skills)
                (%kind-entry "p" "Prompt templates" 'prompt prompt-templates)
                (%kind-entry "x" "Extension commands" 'extension extension-commands))))

(transient:define-menu skills "Pi's skills, as a menu above the chat's."
  (title "Pi's skills"))

(transient:define-menu prompt-templates "Pi's prompt templates, as a menu above the chat's."
  (title "Pi's prompt templates"))

(transient:define-menu extension-commands "Pi's extensions' commands, as a menu above the chat's."
  (title "Pi's extension commands"))

(commands:define-command (%show-above submenu)
  "Shows SUBMENU above the chat's menu."
  (transient:show! submenu))

(commands:define-command (show)
  "Shows the chat's menu."
  (unless (pi-chat:current-chat)
    (error 'pi-menu:show "not in a Pi chat"))
  (transient:show! menu))

(transient:add! menu "Session"
  (transient:command "n" "New" pi-chat:new-session)
  (transient:command "r" "Resume" pi-picker:resume)
  (transient:command "f" "Fork" pi-picker:fork)
  (transient:command "C" "Clone" pi-chat:clone)
  (transient:command "N" "Name" pi-chat:rename-session)
  (transient:command "e" "Export as HTML" pi-chat:export-html)
  (transient:command "R" "Restart Pi" pi-chat:restart)
  (transient:command "Q" "Stop Pi and end the chat" pi-chat:stop))
(transient:add! menu "Context"
  (transient:command "c" "Compact" pi-chat:compact)
  (transient:staying-command "a" (%with-state "Pi's own compaction" %auto-compaction)
                             pi-chat:toggle-auto-compaction))
(transient:add! menu "Model"
  (transient:command "m" (%with-state "Model" %model-name) pi-picker:select-model)
  (transient:command "t" (%with-state "Thinking level" %thinking-level) pi-picker:select-thinking-level))
(transient:add! menu "Display"
  (transient:staying-command "T" %thinking-shown chat:toggle-thinking)
  (transient:staying-command "o" "Fold or unfold every block" chat:toggle-all-blocks))
(transient:add-computed! menu "Pi's commands" %kind-entries)
(transient:add-computed! skills #f (%command-entries 'skill))
(transient:add-computed! prompt-templates #f (%command-entries 'prompt))
(transient:add-computed! extension-commands #f (%command-entries 'extension))

(keys:bind! pi-chat:keymap "C-c C-p" show)

(tables:set! commands:command-modes show (list pi-chat:mode))
