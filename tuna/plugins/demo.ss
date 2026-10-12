;;; Demo commands for the architecture skeleton: endless commands to quit,
;;; describe-services, a *welcome* buffer built as a tree, swapping the text
;;; store, the renderer, the window manager, and basic editing while Tuna
;;; runs, renaming a buffer through the minibuffer, and a deliberately slow
;;; highlighter that colors digits from a job. The demo turns other plugins
;;; on and off, so it imports them;
;;; ordinary plugins do not.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/help
        :tuna/services/settings
        :tuna/services/minibuffer
        :tuna/plugins/string-text-store
        :tuna/plugins/basic-editing
        :tuna/plugins/plain-text-renderer
        :tuna/plugins/two-windows)
(export demo-plugin
        services-description
        welcome-buffer
        digit-spans
        digit-highlight-delay)

(defsetting digit-highlight-delay 0.3
  "Seconds the demo's slow highlighter takes to color digits.")

;; One line per service: name, tier, provider, dependents.
(def (services-description) => :list
  (map (lambda ((info : service-info))
         (string-append (symbol->string (service-info-name info))
                        " (" (symbol->string (service-info-tier info)) ")"
                        "  provider: "
                        (let (provider (service-info-provider info))
                          (if provider (symbol->string provider) "none"))
                        "  dependents: "
                        (let ((dependents (service-info-dependents info))
                              (adapting (service-info-adapting info)))
                          (if (null? dependents)
                            "none"
                            (string-join (map (lambda ((name : :symbol))
                                                (string-append (symbol->string name)
                                                               (if (memq name adapting) " (adapts)" "")))
                                              dependents)
                                         ", ")))))
       (describe-services)))

;; Spans of S's digit runs, with the face `digit`. A job runs this off the
;; baton: it reads only the snapshot.
(def (digit-spans (s : snapshot)) => :list
  (let ((spans [])
        (position 1)
        (run-start #f))
    (snapshot-for-each-chunk
     s (lambda ((chunk : :string))
         (string-for-each
          (lambda (c)
            (cond
             ((char-numeric? c)
              (unless run-start (set! run-start position)))
             (run-start
              (set! spans (cons (make-span run-start position 'digit) spans))
              (set! run-start #f)))
            (set! position (fx1+ position)))
          chunk)))
    (reverse (if run-start (cons (make-span run-start position 'digit) spans) spans))))

;; After each change, recolor the text's digits from a job. Typing goes on
;; meanwhile; the rebase policy moves the colors past what was typed.
(def (highlight-digits-later! (ctx : context) (t : text)) => :void
  (when (editor-loop-running?)
    (start-job ['highlight-digits (text-id t)]
               input: [(text-snapshot t) (setting-value digit-highlight-delay)]
               run: (lambda (input)
                      (match input
                        ([snapshot delay]
                         (thread-sleep! delay)
                         (digit-spans snapshot))))
               apply: (lambda (spans) (set-highlights! t 'digits spans))
               target: t
               validity: 'rebase
               context: ctx)
    (void)))

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
  "Demo commands: endless loops to quit with C-g, describe-services, a tree buffer, and swaps."
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
  (define-command ctx (rename-buffer) "Give the current buffer a new name, asked in the minibuffer."
    (let (name (read-string "New name: "))
      (when (string-empty? name)
        (error "Empty string is invalid as a buffer name"))
      (rename-buffer! (current-buffer) name)
      (message (string-append "Renamed to " name))))
  (context-add-hook! ctx after-change-hook 'slow-digit-highlighter
                     (lambda (t c) (highlight-digits-later! ctx t)))
  (define-command ctx (toggle-basic-editing) "Turn the basic-editing plugin off or on."
    (toggle-plugin! basic-editing-plugin)
    (message (if (plugin-active? basic-editing-plugin) "Basic editing on" "Basic editing off")))
  (define-command ctx (swap-renderer) "Switch between the HTML and the plain-text renderer."
    (toggle-plugin! plain-text-renderer-plugin)
    (message (if (plugin-active? plain-text-renderer-plugin)
               "Renderer: plain text"
               "Renderer: HTML")))
  (define-command ctx (swap-window-manager) "Switch between one window and two side by side."
    (toggle-plugin! two-windows-plugin)
    (message (if (plugin-active? two-windows-plugin)
               "Window manager: two windows"
               "Window manager: one window")))
  (keymap-set ctx "C-c l" 'loop-forever)
  (keymap-set ctx "C-c L" 'loop-forever-ignoring-quit)
  (keymap-set ctx "C-h s" 'describe-services)
  (keymap-set ctx "C-c b" 'switch-demo-buffer)
  (keymap-set ctx "C-c s" 'swap-text-store)
  (keymap-set ctx "C-c p" 'toggle-basic-editing)
  (keymap-set ctx "C-c r" 'rename-buffer)
  (keymap-set ctx "C-c v" 'swap-renderer)
  (keymap-set ctx "C-c w" 'swap-window-manager))
