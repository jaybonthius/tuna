#lang :tuna/prelude
;;; The region (Emacs's Transient Mark mode, shift selection and
;;; delete-selection-mode), in the selected view: C-SPC sets the mark and
;;; activates the region, C-x C-x swaps point and the mark, and C-g
;;; deactivates it. A command that edits the selected view's text
;;; deactivates it when it ends.
;;;
;;; Shift selection: a motion command (`shift-select-commands`) whose keys
;;; were found by shift translation (the keys contract) activates a
;;; temporary region from where point was, unless one is already active;
;;; an unshifted motion command ends a temporary region, such as one the
;;; mouse made (`set-temporary-region!`), but not one C-SPC made. Which commands are motions is this plugin's list, not a mark on
;;; the commands: Emacs marks them with `^` in their interactive specs.
;;;
;;; With the delete-selection setting on, typing, RET, DEL, C-d and
;;; yanking replace a non-empty active region: advice on those commands,
;;; outside any other.
(import :std/interface
        (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/region/contract)
(export region)

;; The motion commands of other plugins that shifted keys select with.
(def shift-select-commands
  '(forward-char backward-char next-line previous-line
    move-beginning-of-line move-end-of-line beginning-of-buffer end-of-buffer
    scroll-up-command scroll-down-command))

;; Commands that insert in place of an active region when delete-selection
;; is on, and those that delete it instead of doing what they do.
(def delete-selection-inserting-commands '(self-insert-command newline yank))
(def delete-selection-deleting-commands '(delete-backward-char delete-char))

;; TEMPORARY: views whose active region shift selection made. EDITED: the
;; views whose focused text a running command changed while selected,
;; deactivated when a command ends (nested ones too, as M-x runs them).
(defclass region-state ((temporary : HashTable)
                        (edited    : :list))
  final: #t)

;; The selected view, when it has a focused text node, or #f.
(def (text-view) => (Maybe view)
  (let (v (selected-view))
    (and (view-node v) v)))

(def (activate! (self : region-state) (v : view) (position : :fixnum) (temporary? : :boolean)) => :void
  (set-view-mark! v position)
  (set-view-mark-active! v #t)
  (if temporary?
    (hash-put! self.temporary v #t)
    (hash-remove! self.temporary v)))

(def (deactivate! (self : region-state) (v : view)) => :void
  (set-view-mark-active! v #f)
  (hash-remove! self.temporary v))

(def (temporary? (self : region-state) (v : view)) => :boolean
  (and (view-mark-active? v) (hash-key? self.temporary v)))

(def (the-mark (v : view)) => :fixnum
  (or (view-mark v)
      (error "The mark is not set now, so there is no region")))

;; Emacs `handle-shift-selection`, before a motion command.
(def (handle-shift-selection! (self : region-state) (v : view)) => :void
  (cond
   ((this-command-keys-shift-translated?)
    (unless (temporary? self v)
      (activate! self v (view-point v) #t)))
   ((temporary? self v)
    (deactivate! self v))))

;; With delete-selection on, delete the selected view's active region, if
;; it is not empty, and return whether it did.
(def (delete-selection! (self : region-state)) => :boolean
  (let (v (text-view))
    (and v (setting-value delete-selection) (view-mark-active? v)
         (let ((p (view-point v))
               (m (the-mark v)))
           (and (not (fx= p m))
                (begin
                  (delete-region (fxmin p m) (fxmax p m))
                  #t))))))

(def (set-mark-command! (self : region-state)) => :void
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
(def (exchange-point-and-mark! (self : region-state)) => :void
  (let* ((v (or (text-view) (error "No text to edit here")))
         (m (or (view-mark v) (error "No mark set in this buffer")))
         (p (view-point v))
         (was-temporary? (temporary? self v)))
    (set-view-point! v m)
    (activate! self v p was-temporary?)))

(implement Region region-state
  (region-active? (lambda (self) (let (v (text-view)) (and v (view-mark-active? v)))))
  (region-beginning (lambda (self) (let (v (or (text-view) (error "No text to edit here")))
                                     (fxmin (view-point v) (the-mark v)))))
  (region-end (lambda (self) (let (v (or (text-view) (error "No text to edit here")))
                               (fxmax (view-point v) (the-mark v)))))
  (deactivate-mark! (lambda (self) (let (v (text-view)) (when v (deactivate! self v)))))
  (set-temporary-region! (lambda (self mark)
                           (let (v (or (text-view) (error "No text to edit here")))
                             (activate! self v mark #t)))))

(defplugin (region ctx)
  "The region: C-SPC sets the mark, C-x C-x swaps it with point, shifted motion keys select, an edit or C-g deactivates."
  provides: [region-service]
  requires: [commands-service input-service buffers-service settings-service]
  (using (self (region-state temporary: (make-hash-table test: eq? weak-keys: #t) edited: []) : region-state)
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
    (context-provide! ctx region-service (Region self))))
