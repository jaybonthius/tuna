;;; Demo commands for the architecture skeleton: endless commands to quit,
;;; describe-services, a *welcome* buffer built as a tree, and swapping the
;;; text store and basic editing while Tuna runs. The demo turns other
;;; plugins on and off, so it imports them; ordinary plugins do not.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/help
        :tuna/plugins/string-text-store
        :tuna/plugins/basic-editing)
(export demo-plugin
        services-description
        welcome-buffer)

;; One line per service: name, tier, provider, dependents.
(def (services-description) => :list
  (map (lambda ((info : service-info))
         (string-append (symbol->string (service-info-name info))
                        " (" (symbol->string (service-info-tier info)) ")"
                        "  provider: "
                        (let (provider (service-info-provider info))
                          (if provider (symbol->string provider) "none"))
                        "  dependents: "
                        (let (dependents (service-info-dependents info))
                          (if (null? dependents)
                            "none"
                            (string-join (map symbol->string dependents) ", ")))))
       (describe-services)))

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

(def (toggle-plugin! (p : plugin)) => :void
  (if (plugin-active? p)
    (deactivate-plugin! p)
    (activate-plugin! p)))

(defplugin (demo-plugin ctx)
  "Demo commands: endless loops to quit with C-g, describe-services, a tree buffer, and swaps."
  requires: [input-service buffers-service]
  (context-define-node-kind! ctx 'column doc: "Children stacked vertically.")
  (context-define-node-kind! ctx 'heading doc: "A heading."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx 'column 'html render-column)
  (context-define-node-renderer! ctx 'heading 'html render-heading)
  (context-add-buffer! ctx (welcome-buffer))
  (define-command ctx (loop-forever) "Loop until quit, checking for quit."
    (message "Looping forever, checking for quit. Press C-g.")
    (redisplay)
    (let lp () (check-quit) (lp)))
  (define-command ctx (loop-forever-ignoring-quit) "Loop until quit, never checking for quit."
    (message "Looping forever without checking for quit. Press C-g.")
    (redisplay)
    ;; Counting keeps gxc -O from hanging on an empty self-loop.
    (let lp ((n 0)) (lp (fxand (fx1+ n) #xffff))))
  (define-command ctx (describe-services) "Show each service's tier, provider, and dependents."
    (show-help "Services" (services-description)))
  (define-command ctx (switch-demo-buffer) "Switch between *scratch* and *welcome*."
    (let (name (if (equal? (buffer-name (current-buffer)) "*welcome*") "*scratch*" "*welcome*"))
      (switch-to-buffer (or (get-buffer name) (error "No buffer named" name)))))
  (define-command ctx (swap-text-store) "Switch between the rope and the plain-string text store."
    (toggle-plugin! string-text-store-plugin)
    (message (if (plugin-active? string-text-store-plugin)
               "Text store: plain strings"
               "Text store: rope")))
  (define-command ctx (toggle-basic-editing) "Turn the basic-editing plugin off or on."
    (toggle-plugin! basic-editing-plugin)
    (message (if (plugin-active? basic-editing-plugin) "Basic editing on" "Basic editing off")))
  (keymap-set ctx "C-c l" 'loop-forever)
  (keymap-set ctx "C-c L" 'loop-forever-ignoring-quit)
  (keymap-set ctx "C-h s" 'describe-services)
  (keymap-set ctx "C-c b" 'switch-demo-buffer)
  (keymap-set ctx "C-c s" 'swap-text-store)
  (keymap-set ctx "C-c p" 'toggle-basic-editing))
