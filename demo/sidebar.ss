;;; The sidebar demo, for development only (demo/init.ss): C-c d shows a
;;; *sidebar* buffer pinned to the left with display-buffer, as the
;;; buffers, views and layout brief's walkthrough does: a list of buttons,
;;; one per buffer (buttons contract). Clicking one shows its buffer in the
;;; selected view, never in the sidebar, whose buffer moving between views
;;; skips (no-other-view). The list is built again whenever a buffer is
;;; added, killed or renamed (buffer-list-update-hook). The sidebar's view
;;; is dedicated, so pressing C-c d again kills the buffer and the view
;;; closes. Turning the plugin off kills it too.
prelude: :gerbil/core

(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/buttons/contract
        (only-in :tuna/plugins/minibuffer/contract minibuffer-view?))
(export sidebar-demo)

(def sidebar-name "*sidebar*")

;; Show the buffer BUTTON names in the selected view, or, should the
;; sidebar or a minibuffer view be selected, in the view after it.
(def (visit-buffer-button (button : node)) => :void
  (let ((b (node-attribute button 'buffer))
        (v (selected-view)))
    (cond
     ((not (memq b (buffer-list))) (message "That buffer is gone"))
     ((or (equal? (buffer-name (view-showing v)) sidebar-name) (minibuffer-view? v))
      (set-view-buffer (next-view v) b))
     (else (set-view-buffer v b)))))

;; A heading, then a button for each buffer that is not internal, other
;; than the sidebar itself, oldest first. The kinds of the heading and the
;; column come from the tree-buffer fixture, and show as plain text
;; without it.
(def (sidebar-children) => :list
  (cons (new-node 'heading attributes: [['content . "Buffers"]])
        (filter-map (lambda ((b : buffer))
                      (and (not (internal-buffer? b))
                           (not (equal? (buffer-name b) sidebar-name))
                           (new-button (buffer-name b) visit-buffer-button
                                       attributes: [['buffer . b]])))
                    (buffer-list))))

(def (refresh-sidebar!) => :void
  (let (b (get-buffer sidebar-name))
    (when b
      (set-node-children! (buffer-root b) (sidebar-children)))))

(def (kill-sidebar!) => :void
  (let (b (get-buffer sidebar-name))
    (when b
      (kill-buffer b))))

(defplugin (sidebar-demo ctx)
  "C-c d shows a sidebar of buffer buttons pinned to the left; again, kills it and its view closes."
  requires: [commands-service input-service buffers-service layout-service]
  (define-command ctx (toggle-sidebar) "Show *sidebar* at the left side, or kill it."
    (if (get-buffer sidebar-name)
      (kill-sidebar!)
      (let (b (new-buffer sidebar-name (new-node 'column children: (sidebar-children))))
        (set-buffer-setting! b no-other-view #t)
        (add-buffer! b)
        (display-buffer b side: 'left size: 1/5))))
  (keymap-set ctx "C-c d" 'toggle-sidebar)
  (context-add-hook! ctx buffer-list-update-hook 'refresh-sidebar refresh-sidebar!)
  (context-defer! ctx kill-sidebar!))
