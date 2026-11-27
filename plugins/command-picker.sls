#!tuna
(import (completion) (commands) (keys) (modes) (views) (options) (tables) (saved))

(saved:define-saved command-history '() (lambda (v) (and (list? v) (for-all string? v))))

(options:define-option command-predicate modes:command-for-view? procedure?
  "A procedure of a command and a view that says whether M-x offers the command while that view is selected.")

(define (%offered? command view)
  (and (commands:command? command) (or (not view) ((command-predicate) command view))))

(define (%read-command-from question h commands)
  (completion:read question
    (list (completion:source
            (candidates (list->vector (map (lambda (c) (cons (symbol->string (commands:command-name c)) c)) commands)))
            (category completion:command-category)))
    h))

(define read-command
  (case-lambda
    [(question) (read-command question command-history)]
    [(question h)
     (let ([view (views:current)])
       (%read-command-from question h
         (filter (lambda (c) (%offered? c view))
                 (map commands:command-named (commands:public-command-names)))))]))

(define (%bound-commands keymaps)
  (let ([found '()])
    (let walk ([keymaps keymaps] [seen '()])
      (for-each
        (lambda (keymap)
          (unless (memq keymap seen)
            (for-each
              (lambda (binding)
                (let ([v (cdr binding)])
                  (cond
                    [(tables:table? v) (walk (list v) (cons keymap seen))]
                    [(and (commands:command? v) (not (memq v found))) (set! found (cons v found))])))
              (keys:bindings keymap))))
        keymaps))
    found))

(define (%mode-commands view)
  (let ([marked (filter (lambda (entry)
                          (and (pair? (cdr entry)) (modes:command-for-view? (car entry) view)))
                        (tables:entries commands:command-modes))])
    (let loop ([cs (append (map car marked) (%bound-commands (modes:active-keymaps #f #f)))] [acc '()])
      (cond
        [(null? cs) (reverse acc)]
        [(and (%offered? (car cs) view) (not (memq (car cs) acc))) (loop (cdr cs) (cons (car cs) acc))]
        [else (loop (cdr cs) acc)]))))

(commands:define-command (execute-extended-command [command (read-command "M-x ")])
  "Runs COMMAND, read by name, passing the prefix argument on."
  (commands:run command))

(commands:define-command (execute-mode-command
                           [command (let ([view (views:current)])
                                      (if view
                                          (%read-command-from "M-X " command-history (%mode-commands view))
                                          (read-command "M-X ")))])
  "Runs COMMAND, read by name from the commands for the modes on in the selected view."
  (commands:run command))

(keys:bind! keys:global "M-x" execute-extended-command)
(keys:bind! keys:global "M-X" execute-mode-command)
