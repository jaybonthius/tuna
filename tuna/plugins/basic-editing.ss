#lang :tuna/prelude
;;; Basic editing: typing, deleting, moving by characters and lines, and
;;; undo. Every command acts on the current view's focused text node, so it
;;; works the same in a one-text buffer and in a tree with other nodes.
;;; Optional services:
;;; - messages-service: notices via the kernel's guarded message dispatcher
;;;   (including stale-click reports); without it, nonempty notices go to stderr.
(import :tuna/services/commands
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers)
(export basic-editing-plugin)

;; Move point to POSITION, or as far as the text allows and signal.
(def (move-to! (position : :fixnum)) => :void
  (cond
   ((fx< position (point-min))
    (goto-char (point-min))
    (error "Beginning of buffer"))
   ((fx> position (point-max))
    (goto-char (point-max))
    (error "End of buffer"))
   (else (goto-char position))))

(def vertical-motion-commands '(next-line previous-line))

;; Move N lines, keeping the goal column across consecutive line motions.
(def (forward-line! (n : :fixnum)) => :void
  (let* ((t (current-text))
         (line (text-line-at t (point)))
         (target (fx+ line n)))
    (unless (and (goal-column) (memq (last-command) vertical-motion-commands))
      (set-goal-column! (text-column t (point))))
    (cond
     ((fx< target 1)
      (goto-char (point-min))
      (error "Beginning of buffer"))
     ((fx> target (text-line-count t))
      (goto-char (point-max))
      (error "End of buffer"))
     (else
      (goto-char (text-position-at t target (or (goal-column) 0)))))))

(def (current-line) => :fixnum
  (text-line-at (current-text) (point)))

(defplugin basic-editing-plugin
  "Typing, deleting, moving by characters and lines, and undo."
  requires: [commands-service input-service buffers-service]
  (defcommand (self-insert-command) "Insert the character typed."
    ;; Consecutive self-inserts undo together, up to 20 (as in Emacs).
    (when (eq? (last-command) 'self-insert-command)
      (undo-amalgamate! (current-text) 20))
    (insert (key-event-key (last-command-event))))
  (defcommand (newline) "Insert a line break."
    (insert "\n"))
  (defcommand (delete-backward-char) "Delete the character before point."
    (let (p (point))
      (when (fx= p (point-min))
        (error "Beginning of buffer"))
      (delete-region (fx1- p) p)))
  (defcommand (delete-char) "Delete the character after point."
    (let (p (point))
      (when (fx= p (point-max))
        (error "End of buffer"))
      (delete-region p (fx1+ p))))
  (defcommand (forward-char) "Move point one character forward."
    (move-to! (fx1+ (point))))
  (defcommand (backward-char) "Move point one character back."
    (move-to! (fx1- (point))))
  (defcommand (next-line) "Move to the next line, keeping the column."
    (forward-line! 1))
  (defcommand (previous-line) "Move to the previous line, keeping the column."
    (forward-line! -1))
  (defcommand (move-beginning-of-line) "Move to the start of the line."
    (goto-char (text-line-start (current-text) (current-line))))
  (defcommand (move-end-of-line) "Move to the end of the line."
    (goto-char (text-line-end (current-text) (current-line))))
  (defcommand (undo) "Undo the last command's changes; repeat to undo earlier ones."
    (goto-char (text-undo! (current-text) (eq? (last-command) 'undo)))
    (message "Undo"))
  (keymap-set printing-char-key 'self-insert-command)
  (keymap-set "SPC" 'self-insert-command)
  (keymap-set "RET" 'newline)
  (keymap-set "DEL" 'delete-backward-char)
  (keymap-set "C-d" 'delete-char)
  (keymap-set "<delete>" 'delete-char)
  (keymap-set "C-f" 'forward-char)
  (keymap-set "<right>" 'forward-char)
  (keymap-set "C-b" 'backward-char)
  (keymap-set "<left>" 'backward-char)
  (keymap-set "C-n" 'next-line)
  (keymap-set "<down>" 'next-line)
  (keymap-set "C-p" 'previous-line)
  (keymap-set "<up>" 'previous-line)
  (keymap-set "C-a" 'move-beginning-of-line)
  (keymap-set "<home>" 'move-beginning-of-line)
  (keymap-set "C-e" 'move-end-of-line)
  (keymap-set "<end>" 'move-end-of-line)
  (keymap-set "C-/" 'undo)
  (keymap-set "C-_" 'undo))
