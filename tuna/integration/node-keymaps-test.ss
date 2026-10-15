;;; Integration: the keys plugin resolving keys and clicks through node
;;; keymaps of the default buffers provider, under the default layout.
;;; Keys start at the focused node, clicks at the node clicked; both walk
;;; up to the buffer's root, then the innermost input target, then the
;;; global keymap. A click is looked up under every one of its names in a
;;; keymap before the next keymap.
(import :tuna/services/commands
        :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/plugins/commands
        :tuna/plugins/keys
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        "../test-support/kernel"
        "../test-support/session"
        "../test-support/two-views"
        (only-in "../test-support/string-input" test-messages-plugin current-message))
(export node-keymaps-test)

(def lookup-plugins
  [commands-plugin keys-plugin test-messages-plugin rope-text-store-plugin settings-plugin no-session-plugin
   buffers-plugin layout-plugin])

(def (keydown (key : :string) ctrl?: (ctrl? : :boolean := #f)) => key-event
  (make-key-event "test-client" 1 key "" 0 #f #f #f ctrl? #f #f #f #f #f #f))

(def (pointer part node: (node #f) area: (area 'view) clicks: (clicks 1))
  (make-pointer-event "test-client" 1 1 clicks #f #f #f #f (make-posn area part node 1)))

;; The name of the command EVENT resolves to, or #f.
(def (resolve event)
  (let (resolved (Input-resolve! (Input (service-provider input-service)) event))
    (and resolved (car resolved))))

;; C-c then KEY.
(def (resolve-c key)
  (resolve (keydown "c" ctrl?: #t))
  (resolve (keydown key)))

;; Keymaps of the tree buffer "tree":
;;   root (ROOT) -> section (SECTION) -> leaf, a text node (LEAF)
;;               -> item (ITEM)
(def root-keymap (new-keymap))
(def section-keymap (new-keymap))
(def leaf-keymap (new-keymap))
(def item-keymap (new-keymap))
(def target-keymap (new-keymap))

(def command-names
  '(global-a global-b global-c global-d global-t global-x view-click global-click
    target-c target-d target-click root-b root-c root-double section-a section-b
    section-click section-view-click leaf-a leaf-x item-click))

(defplugin (layered ctx)
  "Commands, and bindings in every layer."
  requires: [commands-service input-service]
  (for-each (lambda (name) (context-define-command! ctx name void)) command-names)
  (for-each (lambda (binding) (keymap-set! ctx (car binding) (cdr binding) #f))
            '(("C-c a" . global-a) ("C-c b" . global-b) ("C-c c" . global-c) ("C-c d" . global-d)
              ("C-c t" . global-t) ("C-c x" . global-x)
              ("<view> <mouse-1>" . view-click) ("<mouse-1>" . global-click)))
  (for-each (lambda (binding) (keymap-set-in! ctx (car binding) (cadr binding) (caddr binding) #f))
            [[target-keymap "C-c c" 'target-c] [target-keymap "C-c d" 'target-d]
             [root-keymap "C-c b" 'root-b] [root-keymap "C-c c" 'root-c]
             [root-keymap "<double-mouse-1>" 'root-double]
             [section-keymap "C-c a" 'section-a] [section-keymap "C-c b" 'section-b]
             [section-keymap "<mouse-1>" 'section-click]
             [section-keymap "<view> <mouse-1>" 'section-view-click]
             [leaf-keymap "C-c a" 'leaf-a]
             [item-keymap "<mouse-1>" 'item-click]]))

(defplugin (leaf-binder ctx)
  "Binds C-c x and a click on the leaf."
  requires: [input-service]
  (keymap-set-in! ctx leaf-keymap "C-c x" 'leaf-x #f)
  (keymap-set-in! ctx leaf-keymap "<mouse-1>" 'leaf-x #f))

;; Show "tree" in the selected view; its focus is the leaf. Returns the
;; ids of the selected view, the root, the section, the leaf and the item.
(def (show-tree!)
  (let* ((leaf (new-text-node (new-text "leaf")))
         (section (new-node 'section children: [leaf] keymap: section-keymap))
         (item (new-node 'item keymap: item-keymap))
         (root (new-node 'column children: [section item] keymap: root-keymap))
         (b (new-buffer "tree" root)))
    (set-node-keymap! leaf leaf-keymap)
    (add-buffer! b)
    (switch-to-buffer b)
    (map node-id [root section leaf item])))

(def node-keymaps-test
  (test-suite "tuna/integration/node-keymaps"
    (test-case "click resolvers run as their owner and disappear with its receipt"
      (call-with-fresh-kernel lookup-plugins
        (lambda ()
          (activate-plugin! layered)
          (show-tree!)
          (let ((part (view-id (selected-view)))
                (leaf (current-text-node))
                (probe (new-service 'resolver-probe symbol? tier: 'live doc: "Resolver ownership probe."))
                (seen #f))
            (defplugin (resolver-provider ctx) "Only the resolver may query this service."
              provides: [probe]
              (context-provide! ctx probe 'owner-bound))
            (defplugin (resolver-owner ctx) "Resolves a click under its own declarations."
              requires: [input-service probe]
              (context-set-click-resolver! ctx
                (lambda ((p : posn))
                  (set! seen (service-provider probe))
                  leaf)))
            (activate-plugin! leaf-binder)
            (activate-plugin! resolver-provider)
            ;; Declaration order, not registration time, chooses equal entries.
            (activate-plugin! resolver-owner order: 10)
            (check (resolve (pointer part)) => 'leaf-x)
            (check seen => 'owner-bound)
            (deactivate-plugin! resolver-owner)
            (check (resolve (pointer part)) => 'view-click)
            (deactivate-plugin! layout-plugin)
            (check (resolve (pointer part)) => 'view-click)
            (activate-plugin! two-views-plugin)
            (check (resolve (pointer (view-id (selected-view)) node: (node-id leaf))) => 'leaf-x)
            (deactivate-plugin! two-views-plugin)
            (check (resolve (pointer part)) => 'view-click)))))
    (test-case "where-is follows explicit focus, ancestor shadows and prefix shadows"
      (call-with-fresh-kernel lookup-plugins
        (lambda ()
          (activate-plugin! layered)
          (show-tree!)
          (let ((leaf (current-text-node))
                (root (buffer-root (current-buffer))))
            (check (where-is 'leaf-a leaf) => ["C-c a"])
            (check (where-is 'section-a leaf) => [])
            (check (where-is 'global-a leaf) => [])
            (check (where-is 'global-a root) => ["C-c a"])
            (check (where-is 'root-b root) => ["C-c b"])
            (defplugin (prefix-shadow ctx)
              "An exact local prefix hides longer sequences."
              requires: [input-service]
              (keymap-set-in ctx leaf-keymap "C-c" 'leaf-x))
            (activate-plugin! prefix-shadow)
            (check (where-is 'global-t leaf) => [])
            (check (where-is 'leaf-x leaf) => ["C-c"])
            (deactivate-plugin! prefix-shadow)
            (check (where-is 'global-t leaf) => ["C-c t"])))))
    (test-case "keys: the focused node, the nodes above it to the root, the input target, then the global keymap"
      (call-with-fresh-kernel lookup-plugins
       (lambda ()
         (activate-plugin! layered)
         (show-tree!)
         (push-input-target! (make-input-target 'target target-keymap))
         (check (resolve-c "a") => 'leaf-a)
         (check (resolve-c "b") => 'section-b)
         (check (resolve-c "c") => 'root-c)
         (check (resolve-c "d") => 'target-d)
         (check (resolve-c "t") => 'global-t)
         ;; Another buffer: only the target and the global keymap remain.
         (switch-to-buffer (get-buffer "*scratch*"))
         (check (resolve-c "a") => 'global-a)
         (check (resolve-c "c") => 'target-c))))

    (test-case "keys in a buffer without a text node start at its root"
      (call-with-fresh-kernel lookup-plugins
       (lambda ()
         (activate-plugin! layered)
         (let (b (new-buffer "rich" (new-node 'column children: [(new-node 'item)] keymap: root-keymap)))
           (add-buffer! b)
           (switch-to-buffer b)
           (check (resolve-c "b") => 'root-b)
           (check (resolve-c "a") => 'global-a)))))

    (test-case "a node binding shadows the global one, and goes when its plugin is turned off"
      (call-with-fresh-kernel lookup-plugins
       (lambda ()
         (activate-plugin! layered)
         (let* ((ids (show-tree!))
                (v (view-id (selected-view)))
                (leaf (caddr ids)))
           (check (resolve-c "x") => 'global-x)
           (activate-plugin! leaf-binder)
           (check (resolve-c "x") => 'leaf-x)
           (check (resolve (pointer v node: leaf)) => 'leaf-x)
           (deactivate-plugin! leaf-binder)
           (check (resolve-c "x") => 'global-x)
           (check (resolve (pointer v node: leaf)) => 'section-view-click)))))

    (test-case "a node keymap's prefix waits for the rest of the sequence before the global keymap"
      (call-with-fresh-kernel lookup-plugins
       (lambda ()
         (defplugin (prefixes ctx)
           "C-c is a global command; in the leaf it is a prefix."
           requires: [commands-service input-service]
           (context-define-command! ctx 'global-c-c void)
           (context-define-command! ctx 'leaf-c-c-c void)
           (keymap-set! ctx "C-c" 'global-c-c #f)
           (keymap-set-in! ctx leaf-keymap "C-c C-c" 'leaf-c-c-c #f))
         (activate-plugin! prefixes)
         (show-tree!)
         (check (resolve (keydown "c" ctrl?: #t)) => #f)
         (check (current-message) => "C-c-")
         (check (resolve (keydown "c" ctrl?: #t)) => 'leaf-c-c-c)
         (switch-to-buffer (get-buffer "*scratch*"))
         (check (resolve (keydown "c" ctrl?: #t)) => 'global-c-c))))

    (test-case "clicks: the node clicked and the nodes above it, each under every name, then target and global"
      (call-with-fresh-kernel lookup-plugins
       (lambda ()
         (activate-plugin! layered)
         (let* ((ids (show-tree!))
                (v (view-id (selected-view)))
                (root (car ids))
                (section (cadr ids))
                (leaf (caddr ids))
                (item (cadddr ids)))
           ;; The item's <mouse-1> shadows the global <view> <mouse-1>.
           (check (resolve (pointer v node: item)) => 'item-click)
           ;; In one keymap the part kind comes first.
           (check (resolve (pointer v node: leaf)) => 'section-view-click)
           (check (resolve (pointer v node: section)) => 'section-view-click)
           ;; The root binds only a double click; a single one falls through.
           (check (resolve (pointer v node: root)) => 'view-click)
           (check (resolve (pointer v node: root clicks: 2)) => 'root-double)
           ;; With no node clicked, lookup starts at the root of the view's buffer.
           (check (resolve (pointer v clicks: 2)) => 'root-double)
           (check (resolve (pointer v area: 'status-line clicks: 2)) => 'root-double)
           (check (resolve (pointer v)) => 'view-click)
           ;; The input target comes after the nodes, before the global keymap.
           (let (target (make-input-target 'target target-keymap))
             (defplugin (target-click ctx)
               "Binds a click in the target's keymap."
               requires: [input-service]
               (keymap-set-in! ctx target-keymap "<mouse-1>" 'target-click #f))
             (activate-plugin! target-click)
             (push-input-target! target)
             (check (resolve (pointer v node: root)) => 'target-click)
             (check (resolve (pointer v node: item)) => 'item-click)
             (remove-input-target! target))
           ;; A node that is gone, or a view that is gone: the global keymap.
           (check (resolve (pointer v node: 999999)) => 'view-click)
           (check (resolve (pointer 999999 node: item)) => 'view-click)))))))
