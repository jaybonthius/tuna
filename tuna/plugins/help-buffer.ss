;;; Help in a buffer (live tier): help output goes to *Help*, a `help` node
;;; holding a `help-title` node and a text node, shown with display-buffer.
;;; C-h q (quit-help) kills *Help*, which closes a view made for it.
prelude: :gerbil/core

(import :tuna/services/commands
        :std/interface
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/services/help)
(export help-buffer-plugin)

(def help-buffer-name "*Help*")

(defclass help-buffer ((output :? help-output)   ; shown last
                       (shown  :? buffer))       ; *Help*, once made
  final: #t)

(def (live-help-buffer (self : help-buffer)) => (Maybe buffer)
  (let (b self.shown)
    (and b (memq b (buffer-list)) b)))

(def (new-help-buffer) => buffer
  (new-buffer help-buffer-name
              (new-node 'help children: [(new-node 'help-title attributes: [['content . ""]])
                                         (new-text-node (new-text ""))])))

;; Put OUTPUT in *Help*, making it if needed, and show it with point at
;; the start.
(def (show! (self : help-buffer) (output : help-output)) => :void
  (set! self.output output)
  (let* ((b (or (live-help-buffer self)
                (let (b (new-help-buffer))
                  (add-buffer! b)
                  (set! self.shown b)
                  b)))
         (children (node-children (buffer-root b)))
         (body (text-node-content (cadr children))))
    (set-node-attribute! (car children) 'content (help-output-title output))
    (text-replace! body 1 (fx1+ (text-size body)) (string-join (help-output-lines output) "\n"))
    (text-clear-undo! body)
    (set-view-point! (display-buffer b) 1)))

(implement Help help-buffer
  (show-help! (lambda (self output) (show! self output)))
  (current-help (lambda (self) self.output)))

(defplugin (help-buffer-plugin ctx)
  "Shows help output in the *Help* buffer; C-h q closes it."
  requires: [commands-service input-service buffers-service layout-service]
  optional: [messages-service]
  (context-define-node-kind! ctx 'help doc: "Help output: a title, then text.")
  (context-define-node-kind! ctx 'help-title doc: "The title of help output."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx 'help 'html
                                 (lambda (n children) `(div (@ (class "help")) ,@children)))
  (context-define-node-renderer! ctx 'help-title 'html
                                 (lambda (n children) `(h1 ,(node-attribute n 'content))))
  (using (self (help-buffer output: #f shown: #f) : help-buffer)
    (defcommand (quit-help) "Kill *Help*; a view made for it closes."
      (let (b (live-help-buffer self))
        (if b
          (kill-buffer b)
          (message "No help is shown"))))
    (keymap-set "C-h q" 'quit-help)
    (context-defer! ctx (lambda ()
                          (let (b (live-help-buffer self))
                            (when b (kill-buffer b)))))
    (context-provide! ctx help-service (Help self))))
