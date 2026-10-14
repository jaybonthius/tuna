;;; Buttons driven by clicks through the real editor loop: a click on a
;;; button runs its action, which reads the click with event-start and
;;; posn-node; the button's binding shadows the global view click and
;;; goes with the plugin.
(import :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/services/buttons
        :tuna/plugins/keys
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        :tuna/plugins/buttons
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session"
        (only-in "../test-support/string-input" test-messages-plugin current-message))
(export buttons-test)

;; What happened, newest first: (label node-id) for a pushed button, as its
;; action saw the click, and 'view for a click on a view.
(def happened [])

(defplugin (view-clicks ctx)
  "Records a click on a view, standing in for selecting it."
  requires: [input-service]
  (define-command ctx (record-view-click) "Record a click on a view."
    (set! happened (cons 'view happened)))
  (keymap-set ctx "<view> <mouse-1>" 'record-view-click)
  (keymap-set ctx "C-c b" 'push-button))

(def (with-buttons thunk)
  (set! happened [])
  (call-with-fresh-kernel [keys-plugin test-messages-plugin rope-text-store-plugin settings-plugin
                           no-session-plugin buffers-plugin layout-plugin buttons-plugin view-clicks]
    (lambda ()
      (start-editor-loop!)
      (thunk))))

;; The action of every button: what the click it reads names.
(def (record-push b)
  (let (n (posn-node (event-start (last-command-event))))
    (set! happened (cons [(node-attribute b 'label) (node-id n)] happened))))

;; Show "panel", a column of buttons One and Two and a text node, in the
;; selected view. Returns the ids of the view, One, Two and the text node.
(def (show-panel!)
  (call-on-editor-loop
   (lambda ()
     (let* ((one (new-button "One" record-push))
            (two (new-button "Two" record-push))
            (text (new-text-node (new-text "text")))
            (b (new-buffer "panel" (new-node 'column children: [one two text]))))
       (add-buffer! b)
       (switch-to-buffer b)
       (map (lambda (n) (if (node? n) (node-id n) (view-id n))) [(selected-view) one two text])))))

(def (events)
  (call-on-editor-loop (lambda () (reverse happened))))

(def buttons-test
  (test-suite "tuna/plugins/buttons"
    (test-case "a click on a button runs its action, which reads the button clicked"
      (with-buttons
       (lambda ()
         (match (show-panel!)
           ([v one two text]
            (click 'view v node: two)
            (click 'view v node: one)
            ;; Anything else in the view falls back to the view's binding.
            (click 'view v node: text)
            (click 'view v)
            (check (events) => [["Two" two] ["One" one] 'view 'view]))))))

    (test-case "buttons are drawn as buttons out of the tab order; their projection is the label"
      (with-buttons
       (lambda ()
         (call-on-editor-loop
          (lambda ()
            (let (b (new-button "Go" void))
              (check ((node-renderer button-node-kind 'html) b []) 
                     => '(button (@ (type "button") (class "button") (tabindex "-1")) "Go"))
              (check (node-text-projection b) => "Go")
              (check (eq? (node-keymap b) button-keymap) => #t)))))))

    (test-case "with the plugin off, a button's click selects as any click in the view"
      (with-buttons
       (lambda ()
         (match (show-panel!)
           ([v one two text]
            (call-on-editor-loop (lambda () (deactivate-plugin! buttons-plugin)))
            (click 'view v node: one)
            (check (events) => ['view])
            (call-on-editor-loop (lambda () (activate-plugin! buttons-plugin)))
            (click 'view v node: one)
            (check (events) => ['view ["One" one]]))))))

    (test-case "push-button from a key says it needs a click"
      (with-buttons
       (lambda ()
         (show-panel!)
         (type! "C-c" "b")
         (check (call-on-editor-loop current-message) => "push-button runs only from a click")
         (check (events) => []))))))
