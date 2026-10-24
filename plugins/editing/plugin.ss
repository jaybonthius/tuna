#lang :tuna/prelude
;;; Editing text, in the selected view's focused text node, so it works
;;; the same in a one-text buffer and in a tree with other nodes:
;;;
;;; - typing, deleting, moving by characters and lines and to either end,
;;;   and undo;
;;; - the region (Emacs's Transient Mark mode, shift selection and
;;;   delete-selection-mode): C-SPC sets the mark and activates the
;;;   region, C-x C-x swaps point and the mark, and C-g deactivates it; a
;;;   command that edits the selected view's text deactivates it when it
;;;   ends;
;;; - the kill ring, and the commands that kill, copy and yank through it:
;;;   C-w (kill-region), M-w (kill-ring-save), C-y (yank) and M-y
;;;   (yank-pop, right after a yank). Killing and copying take the region
;;;   between point and the mark, active or not, as in Emacs. A paste from
;;;   the browser (`<paste>`) runs clipboard-yank, which puts the pasted
;;;   text on the kill ring and yanks it, as Emacs's `xterm-paste` does for
;;;   a terminal's paste;
;;; - clicking and dragging in text (mouse.ss).
;;;
;;; Shift selection: a motion command (`shift-select-commands`) whose keys
;;; were found by shift translation (the keys contract) activates a
;;; temporary region from where point was, unless one is already active;
;;; an unshifted motion command ends a temporary region, such as one the
;;; mouse made (`set-temporary-region!`), but not one C-SPC made. Which
;;; commands are motions is this plugin's list, not a mark on the
;;; commands: Emacs marks them with `^` in their interactive specs.
;;;
;;; With the delete-selection setting on, typing, RET, DEL, C-d, yanking
;;; and pasting replace a non-empty active region: advice on those
;;; commands, outside any other.
(import :std/interface
        (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        (only-in :tuna/plugins/layout/contract layout-service)
        :tuna/plugins/editing/contract
        "mouse")
(export editing
        kill-ring-max)

(defsetting kill-ring-max 120 "How many texts the kill ring keeps; older ones are dropped.")

;;; Moving

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

;;; The region and the kill ring

;; The motion commands that shifted keys select with.
(def shift-select-commands
  '(forward-char backward-char next-line previous-line
    move-beginning-of-line move-end-of-line beginning-of-buffer end-of-buffer
    scroll-up-command scroll-down-command))

;; Commands that insert in place of an active region when delete-selection
;; is on, and those that delete it instead of doing what they do.
(def delete-selection-inserting-commands '(self-insert-command newline yank clipboard-yank))
(def delete-selection-deleting-commands '(delete-backward-char delete-char))

;; TEMPORARY: views whose active region shift selection made. EDITED: the
;; views whose focused text a running command changed while selected,
;; deactivated when a command ends (nested ones too, as M-x runs them).
;; TEXTS: the kill ring, newest first, and POINTER the index of the one
;; the yank pointer points at.
(defclass editing-state ((temporary : HashTable)
                         (edited    : :list)
                         (texts     : :list)
                         (pointer   : :fixnum))
  final: #t)

;; The selected view, when it has a focused text node, or #f.
(def (text-view) => (Maybe view)
  (let (v (selected-view))
    (and (view-node v) v)))

(def (activate! (self : editing-state) (v : view) (position : :fixnum) (temporary? : :boolean)) => :void
  (set-view-mark! v position)
  (set-view-mark-active! v #t)
  (if temporary?
    (hash-put! self.temporary v #t)
    (hash-remove! self.temporary v)))

(def (deactivate! (self : editing-state) (v : view)) => :void
  (set-view-mark-active! v #f)
  (hash-remove! self.temporary v))

(def (temporary? (self : editing-state) (v : view)) => :boolean
  (and (view-mark-active? v) (hash-key? self.temporary v)))

(def (the-mark (v : view)) => :fixnum
  (or (view-mark v)
      (error "The mark is not set now, so there is no region")))

;; Emacs `handle-shift-selection`, before a motion command.
(def (handle-shift-selection! (self : editing-state) (v : view)) => :void
  (cond
   ((this-command-keys-shift-translated?)
    (unless (temporary? self v)
      (activate! self v (view-point v) #t)))
   ((temporary? self v)
    (deactivate! self v))))

;; With delete-selection on, delete the selected view's active region, if
;; it is not empty, and return whether it did.
(def (delete-selection! (self : editing-state)) => :boolean
  (let (v (text-view))
    (and v (setting-value delete-selection) (view-mark-active? v)
         (let ((p (view-point v))
               (m (the-mark v)))
           (and (not (fx= p m))
                (begin
                  (delete-region (fxmin p m) (fxmax p m))
                  #t))))))

(def (set-mark-command! (self : editing-state)) => :void
  (let (v (text-view))
    (unless v (error "No text to edit here"))
    (when (temporary? self v)
      (deactivate! self v))
    (cond
     ((not (eq? (last-command) 'set-mark-command))
      (activate! self v (view-point v) #f)
      (message "Mark set"))
     ((view-mark-active? v)
      (deactivate! self v)
      (message "Mark deactivated"))
     (else
      (set-view-mark-active! v #t)
      (message "Mark activated")))))

;; Swap point and the mark, and activate the region; a temporary region
;; stays temporary.
(def (exchange-point-and-mark! (self : editing-state)) => :void
  (let* ((v (or (text-view) (error "No text to edit here")))
         (m (or (view-mark v) (error "No mark set in this buffer")))
         (p (view-point v))
         (was-temporary? (temporary? self v)))
    (set-view-point! v m)
    (activate! self v p was-temporary?)))

(def (kill-new! (self : editing-state) (text : :string)) => :void
  (let ((limit (:- (setting-value kill-ring-max) :fixnum))
        (texts (cons text self.texts)))
    (set! self.texts (if (fx< 0 limit (length texts)) (take texts limit) texts))
    (set! self.pointer 0)))

(def (current-kill! (self : editing-state) (n : :fixnum)) => :string
  (when (null? self.texts)
    (error "Kill ring is empty"))
  (set! self.pointer (modulo (fx+ self.pointer n) (length self.texts)))
  (list-ref self.texts self.pointer))

(implement Editing editing-state
  (region-active? (lambda (self) (let (v (text-view)) (and v (view-mark-active? v)))))
  (region-beginning (lambda (self) (let (v (or (text-view) (error "No text to edit here")))
                                     (fxmin (view-point v) (the-mark v)))))
  (region-end (lambda (self) (let (v (or (text-view) (error "No text to edit here")))
                               (fxmax (view-point v) (the-mark v)))))
  (deactivate-mark! (lambda (self) (let (v (text-view)) (when v (deactivate! self v)))))
  (set-temporary-region! (lambda (self mark)
                           (let (v (or (text-view) (error "No text to edit here")))
                             (activate! self v mark #t))))
  (kill-new (lambda (self text) (kill-new! self text)))
  (current-kill (lambda (self n) (current-kill! self n))))

(def yank-commands '(yank yank-pop clipboard-yank))

;; Insert TEXT at point, with the mark before it (Emacs `yank`).
(def (yank-text! (text : :string)) => :void
  (set-view-mark! (selected-view) (point))
  (insert text)
  (message "Mark set"))

(defplugin (editing ctx)
  "Typing, deleting, moving and undo; the region (C-SPC, C-x C-x, shift selection); the kill ring (C-w, M-w, C-y, M-y, paste); clicking and dragging in text."
  provides: [editing-service]
  requires: [commands-service input-service buffers-service settings-service]
  optional: [layout-service]          ; the mouse commands, which run only from a pointer event on a layout's screen
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
  (defcommand (beginning-of-buffer) "Move point to the beginning of the text."
    (goto-char (point-min)))
  (defcommand (end-of-buffer) "Move point to the end of the text."
    (goto-char (point-max)))
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
  (keymap-set "M-<" 'beginning-of-buffer)
  (keymap-set "M->" 'end-of-buffer)
  (keymap-set "C-/" 'undo)
  (keymap-set "C-_" 'undo)
  (using (self (editing-state temporary: (make-hash-table test: eq? weak-keys: #t) edited: []
                              texts: [] pointer: 0)
               : editing-state)
    (context-add-hook! ctx pre-command-hook 'region
                       (lambda ()
                         (when (memq (this-command) shift-select-commands)
                           (let (v (text-view))
                             (when v (handle-shift-selection! self v))))))
    (context-add-hook! ctx after-change-hook 'region
                       (lambda ((t : text) (c : change))
                         (let (v (and (this-command) (text-view)))
                           (when (and v (eq? (text-node-content (view-node v)) t) (not (memq v self.edited)))
                             (set! self.edited (cons v self.edited))))))
    (context-add-hook! ctx post-command-hook 'region
                       (lambda ()
                         (for-each (cut deactivate! self <>) self.edited)
                         (set! self.edited [])))
    (advise! ctx (command-target 'keyboard-quit) 'region before:
             (lambda () (let (v (text-view)) (when v (deactivate! self v)))))
    (for-each (lambda ((name : :symbol))
                (advise! ctx (command-target name) 'delete-selection before:
                         (lambda () (delete-selection! self))
                         depth: -100))
              delete-selection-inserting-commands)
    (for-each (lambda ((name : :symbol))
                (advise! ctx (command-target name) 'delete-selection around:
                         (lambda ((original : :procedure)) (unless (delete-selection! self) (original)))
                         depth: -100))
              delete-selection-deleting-commands)
    (define-command ctx (set-mark-command)
      "Set the mark at point and activate the region; repeated, deactivate or reactivate it."
      (set-mark-command! self))
    (define-command ctx (exchange-point-and-mark)
      "Put the mark where point is and point where the mark was, and activate the region."
      (exchange-point-and-mark! self))
    (keymap-set ctx "C-SPC" 'set-mark-command)
    (keymap-set ctx "C-x C-x" 'exchange-point-and-mark)
    (context-provide! ctx editing-service (Editing self)))
  (defcommand (kill-region) "Delete the text between point and the mark, and put it on the kill ring."
    (let ((start (region-beginning))
          (end (region-end)))
      (kill-new (text-substring (current-text) start end))
      (delete-region start end)))
  (defcommand (kill-ring-save) "Put the text between point and the mark on the kill ring, and deactivate the region."
    (kill-new (text-substring (current-text) (region-beginning) (region-end)))
    (deactivate-mark!))
  (defcommand (yank) "Insert the newest kill, with the mark before it and point after it."
    (yank-text! (current-kill 0)))
  (defcommand (clipboard-yank) "Insert the text the browser's paste key took from the clipboard, and put it on the kill ring."
    (let (event (last-command-event))
      (unless (paste-event? event)
        (error "clipboard-yank runs from the browser's paste key"))
      (let (text (paste-event-text event))
        (kill-new text from-clipboard?: #t)
        (yank-text! text))))
  (defcommand (yank-pop) "Replace the text just yanked with the kill before it; only right after a yank."
    (unless (memq (last-command) yank-commands)
      (error "Previous command was not a yank"))
    (let* ((v (selected-view))
           (p (point))
           (m (or (view-mark v) p))
           (start (fxmin p m))
           (text (current-kill 1)))
      (delete-region start (fxmax p m))
      (goto-char start)
      (set-view-mark! v start)
      (insert text)))
  (keymap-set "C-w" 'kill-region)
  (keymap-set "M-w" 'kill-ring-save)
  (keymap-set "C-y" 'yank)
  (keymap-set "M-y" 'yank-pop)
  (keymap-set paste-key 'clipboard-yank)
  (define-mouse-commands! ctx))
