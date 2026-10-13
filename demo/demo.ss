;;; The demo plugin, for development only (`make demo`, demo/init.ss): a
;;; *welcome* buffer built as a tree (C-c b), and swapping the text store
;;; (C-c s) and basic editing (C-c p) while Tuna runs. The demo's other
;;; commands are test fixtures from tuna/test-support/ that demo/init.ss
;;; declares beside it. It turns other plugins on and off, so it imports
;;; them; ordinary plugins do not. Nothing in tuna/ or starter/ may import
;;; it (tuna/kernel/boundary-test.ss).
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/plugins/basic-editing
        "../tuna/test-support/string-text-store"
        (only-in "../tuna/test-support/plain-text-renderer" join-runs))
(export demo-plugin
        welcome-buffer)

;; (column (heading "Welcome to Tuna") (text "…"))
(def (welcome-buffer) => buffer
  (new-buffer "*welcome*"
              (new-node 'column
                        children: [(new-node 'heading attributes: [['content . "Welcome to Tuna"]])
                                   (new-text-node
                                    (new-text "This buffer is a tree: a column holding a heading and this text.\nType here; the heading stays.\n"))])))

(def (render-column (n : node) (children : :list)) => :list
  `(div (@ (class "column")) ,@children))

(def (render-heading (n : node) (children : :list)) => :list
  `(h1 (@ (class "heading")) ,(node-attribute n 'content)))

;; For the plain-text renderer: the heading underlined.
(def (heading-runs (n : node) (children : :list)) => :list
  (let (content (node-attribute n 'content))
    [content "\n" (make-string (string-length content) #\=)]))

(def (toggle-plugin! (p : plugin)) => :void
  (if (plugin-active? p)
    (deactivate-plugin! p)
    (activate-plugin! p)))

(defplugin (demo-plugin ctx)
  "Demo commands: a tree buffer, and swapping the text store and basic editing."
  requires: [input-service buffers-service]
  (def previous-buffer #f)              ; where C-c b returns from *welcome*
  (context-define-node-kind! ctx 'column doc: "Children stacked vertically.")
  (context-define-node-kind! ctx 'heading doc: "A heading."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx 'column 'html render-column)
  (context-define-node-renderer! ctx 'heading 'html render-heading)
  (context-define-node-renderer! ctx 'column 'plain-text (lambda (n children) (join-runs children)))
  (context-define-node-renderer! ctx 'heading 'plain-text heading-runs)
  (context-add-buffer! ctx (welcome-buffer))
  (define-command ctx (switch-demo-buffer) "Switch to *welcome*, and from it back to the buffer before."
    (let (welcome (or (get-buffer "*welcome*") (error "No buffer named" "*welcome*")))
      (if (eq? (current-buffer) welcome)
        (let (back (if (memq previous-buffer (buffer-list)) previous-buffer (other-buffer welcome)))
          (when back (switch-to-buffer back)))
        (begin
          (set! previous-buffer (current-buffer))
          (switch-to-buffer welcome)))))
  (define-command ctx (swap-text-store) "Switch between the rope and the plain-string text store."
    (toggle-plugin! string-text-store-plugin)
    (message (if (plugin-active? string-text-store-plugin)
               "Text store: plain strings"
               "Text store: rope")))
  (define-command ctx (toggle-basic-editing) "Turn the basic-editing plugin off or on."
    (toggle-plugin! basic-editing-plugin)
    (message (if (plugin-active? basic-editing-plugin) "Basic editing on" "Basic editing off")))
  (keymap-set ctx "C-c b" 'switch-demo-buffer)
  (keymap-set ctx "C-c p" 'toggle-basic-editing)
  (keymap-set ctx "C-c s" 'swap-text-store))
