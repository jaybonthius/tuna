#lang :tuna/prelude
;;; The kill ring, and the commands that kill, copy and yank through it:
;;; C-w (kill-region), M-w (kill-ring-save), C-y (yank) and M-y (yank-pop,
;;; right after a yank). Killing and copying take the region between point
;;; and the mark, active or not, as in Emacs.
(import :std/interface
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/region/contract
        :tuna/plugins/kill-ring/contract)
(export kill-ring
        kill-ring-max)

(defsetting kill-ring-max 120 "How many texts the kill ring keeps; older ones are dropped.")

;; TEXTS, newest first, and the index of the one the yank pointer points at.
(defclass kill-ring-state ((texts   : :list)
                           (pointer : :fixnum))
  final: #t)

(def (kill-new! (self : kill-ring-state) (text : :string)) => :void
  (let ((limit (:- (setting-value kill-ring-max) :fixnum))
        (texts (cons text self.texts)))
    (set! self.texts (if (fx< 0 limit (length texts)) (take texts limit) texts))
    (set! self.pointer 0)))

(def (current-kill! (self : kill-ring-state) (n : :fixnum)) => :string
  (when (null? self.texts)
    (error "Kill ring is empty"))
  (set! self.pointer (modulo (fx+ self.pointer n) (length self.texts)))
  (list-ref self.texts self.pointer))

(implement KillRing kill-ring-state
  (kill-new (lambda (self text) (kill-new! self text)))
  (current-kill (lambda (self n) (current-kill! self n))))

(def yank-commands '(yank yank-pop))

(defplugin (kill-ring ctx)
  "The kill ring: C-w kills the region, M-w copies it, C-y yanks the last kill and M-y replaces it with earlier ones."
  provides: [kill-ring-service]
  requires: [commands-service input-service settings-service buffers-service region-service]
  (using (self (kill-ring-state texts: [] pointer: 0) : kill-ring-state)
    (context-provide! ctx kill-ring-service (KillRing self)))
  (defcommand (kill-region) "Delete the text between point and the mark, and put it on the kill ring."
    (let ((start (region-beginning))
          (end (region-end)))
      (kill-new (text-substring (current-text) start end))
      (delete-region start end)))
  (defcommand (kill-ring-save) "Put the text between point and the mark on the kill ring, and deactivate the region."
    (kill-new (text-substring (current-text) (region-beginning) (region-end)))
    (deactivate-mark!))
  (defcommand (yank) "Insert the newest kill, with the mark before it and point after it."
    (let ((text (current-kill 0))
          (v (selected-view)))
      (set-view-mark! v (point))
      (insert text)
      (message "Mark set")))
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
  (keymap-set "M-y" 'yank-pop))
