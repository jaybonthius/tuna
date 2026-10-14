#lang :tuna/prelude
;;; View and frame commands that work under any layout, because they use
;;; only the layout contract (ADR 13): selecting, splitting, deleting and
;;; moving between views, pointing the frame at the selected view, at the
;;; node at point, or back at the whole layout, and frame marks. A layout
;;; that cannot do one of these says so or falls back as the contract
;;; allows. Commands that need one layout's own arrangement (tabs, zooming
;;; one level) come with that layout plugin.
;;;
;;; Clicking a view or its status line selects that view
;;; (`mouse-select-view`, Emacs `mouse-select-window`), unless its buffer
;;; is skipped by `other-view` (`no-other-view`: the bar's views).
(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/minibuffer
        :tuna/services/layout)
(export view-commands-plugin)

(def (select-neighbor (direction : :symbol) (where : :string)) => :void
  (let (v (neighbor-view (selected-view) direction))
    (if v
      (select-view v)
      (message (string-append "No view " where)))))

;; Select the view the click being handled names, unless its buffer is
;; skipped by other-view.
(def (select-clicked-view) => :void
  (let (p (event-start (last-command-event)))
    (cond
     ((not p) (message "mouse-select-view runs only from a click"))
     ((posn-view p)
      => (lambda ((v : view))
           (unless (view-skipped? v)
             (select-view v))))
     (else (report-stale-click p)))))

(defplugin view-commands-plugin
  "View commands for any layout: C-x o, C-x 0 to 3, S-arrows, frames (C-x n), frame marks (C-x r), clicking a view."
  requires: [input-service buffers-service layout-service]
  (defcommand (mouse-select-view) "Select the view clicked on, or the view whose status line was clicked."
    (select-clicked-view))
  (defcommand (other-view) "Select the next view, cyclically."
    (select-view (next-view (selected-view))))
  (defcommand (split-view-below) "Split the selected view: a new view of its buffer below it."
    (split-view (selected-view) 'below))
  (defcommand (split-view-right) "Split the selected view: a new view of its buffer to its right."
    (split-view (selected-view) 'right))
  (defcommand (delete-view) "Remove the selected view from the layout."
    (delete-view (selected-view)))
  (defcommand (frame-to-selected-view) "Point the frame at the selected view, so it fills the screen."
    (move-frame (make-frame-target (view-id (selected-view)) #f)))
  (defcommand (frame-to-node-at-point) "Point the frame at the node holding point; for a buffer with one text node, the whole view."
    (let* ((v (selected-view))
           (n (view-node v)))
      (move-frame (make-frame-target (view-id v)
                                     (and n (not (eq? n (buffer-root (view-showing v)))) n)))))
  (defcommand (frame-to-top) "Point the frame at the whole layout."
    (move-frame (make-frame-target #f #f)))
  (defcommand (select-view-left) "Select the view to the left."
    (select-neighbor 'left "to the left"))
  (defcommand (select-view-right) "Select the view to the right."
    (select-neighbor 'right "to the right"))
  (defcommand (select-view-up) "Select the view above."
    (select-neighbor 'up "above"))
  (defcommand (select-view-down) "Select the view below."
    (select-neighbor 'down "below"))
  (defcommand (set-frame-mark) "Save where the frame points under a name read in the minibuffer."
    (let (name (read-string "Set frame mark: "))
      (set-frame-mark name)
      (message (string-append "Frame mark " name " set"))))
  (defcommand (jump-to-frame-mark) "Point the frame where a frame mark, named in the minibuffer, points."
    (let (name (read-string "Jump to frame mark: "))
      (case (jump-to-frame-mark name)
        ((unknown) (message (string-append "No frame mark named " name)))
        ((gone) (message (string-append "Frame mark " name " pointed at a part that is gone; dropped it")))
        (else (void)))))
  (defcommand (list-frame-marks) "Show the frame marks' names in the echo area."
    (let (names (frame-mark-names))
      (message (if (null? names)
                 "No frame marks"
                 (string-append "Frame marks: " (string-join names ", "))))))
  (keymap-set "C-x o" 'other-view)
  (keymap-set "C-x 2" 'split-view-below)
  (keymap-set "C-x 3" 'split-view-right)
  (keymap-set "C-x 0" 'delete-view)
  (keymap-set "C-x 1" 'frame-to-selected-view)
  (keymap-set "C-x n s" 'frame-to-node-at-point)
  (keymap-set "C-x n w" 'frame-to-top)
  (keymap-set "S-<left>" 'select-view-left)
  (keymap-set "S-<right>" 'select-view-right)
  (keymap-set "S-<up>" 'select-view-up)
  (keymap-set "S-<down>" 'select-view-down)
  (keymap-set "C-x r w" 'set-frame-mark)
  (keymap-set "C-x r j" 'jump-to-frame-mark)
  (keymap-set "C-x r l" 'list-frame-marks)
  (keymap-set "<view> <mouse-1>" 'mouse-select-view)
  (keymap-set "<status-line> <mouse-1>" 'mouse-select-view))
