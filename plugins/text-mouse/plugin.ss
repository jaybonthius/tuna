#lang :tuna/prelude
;;; Clicking in text (Emacs's mouse.el): a plain left click in a view runs
;;; `mouse-set-point`, which selects the view, as a click in a window does
;;; in Emacs, and moves its point to the gap between characters clicked
;;; (the layout contract's `posn-point`), deactivating its region; a click
;;; below the view's text goes to the text's end, and one on a line that
;;; is gone says so. A node's own click binding, such as a button's or a
;;; completion row's, shadows it. Views whose buffer other-view skips (the
;;; bar's) refuse, as `mouse-select-view` does.
(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/region/contract
        :tuna/plugins/layout/contract)
(export text-mouse)

;; Select the view the click being handled names and move its point where
;; the click was, when that is in the view's focused text node.
(def (set-point-from-click) => :void
  (let (p (event-start (last-command-event)))
    (cond
     ((not p) (message "mouse-set-point runs only from a click"))
     ((posn-view p)
      => (lambda ((v : view))
           (unless (view-skipped? v)
             (select-view v)
             (let ((position (posn-point p))
                   (n (view-node v)))
               (cond
                ((and position n (or (not (posn-node-id p)) (eq? (posn-node p) n)))
                 (deactivate-mark!)
                 (set-view-point! v position))
                ((and (posn-line p) (not position))
                 (report-stale-click p what: "line"))
                (else (void)))))))
     (else (report-stale-click p)))))

(defplugin text-mouse
  "Clicking in text: a click in a view selects it and moves its point there."
  requires: [commands-service input-service buffers-service layout-service region-service]
  (defcommand (mouse-set-point) "Select the view clicked in and move its point to where the click was, deactivating the region."
    (set-point-from-click))
  (keymap-set "<view> <mouse-1>" 'mouse-set-point))
