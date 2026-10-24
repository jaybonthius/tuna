#lang :tuna/prelude
;;; Help in a buffer (live tier): help output goes to *Help*, a `help` node
;;; holding a `help-title` node and a text node, shown with display-buffer.
;;; C-h q (quit-help) kills *Help*, which closes a view made for it. The
;;; describe commands show their output there: describe-advice
;;; (describe-advice.ss), and describe-stylesheets and reload-stylesheets
;;; (describe-stylesheets.ss).

(import :tuna/plugins/commands/contract
        :std/interface
        :tuna/kernel
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/help/contract
        "describe-advice"
        "describe-stylesheets")
(export help)

(def help-buffer-name "*Help*")

(defclass buffer-help ((output :? help-output)   ; shown last
                       (shown  :? buffer))       ; *Help*, once made
  final: #t)

(def (live-help-buffer (self : buffer-help)) => (Maybe buffer)
  (let (b self.shown)
    (and b (memq b (buffer-list)) b)))

(def (new-help-buffer) => buffer
  (new-buffer help-buffer-name
              (new-node 'help children: [(new-node 'help-title attributes: [['content . ""]])
                                         (new-text-node (new-text ""))])))

;; Put OUTPUT in *Help*, making it if needed, and show it with point at
;; the start.
(def (show! (self : buffer-help) (output : help-output)) => :void
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

(implement Help buffer-help
  (show-help! (lambda (self output) (show! self output)))
  (current-help (lambda (self) self.output)))

(defplugin (help ctx)
  "Shows help output in the *Help* buffer; C-h q closes it. M-x describe-advice, describe-stylesheets, reload-stylesheets."
  provides: [help-service]
  requires: [commands-service input-service buffers-service layout-service]
  ;; Completion only for describe-advice's choice, which says when no
  ;; plugin provides it.
  optional: [completion-service completion-ui-service]
  (add-stylesheet 'rules "rules.css")
  (context-define-node-kind! ctx 'help doc: "Help output: a title, then text.")
  (context-define-node-kind! ctx 'help-title doc: "The title of help output."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx 'help
                                 (lambda (n children) `(div (@ (class "help")) ,@children)))
  (context-define-node-renderer! ctx 'help-title
                                 (lambda (n children) `(h1 ,(node-attribute n 'content))))
  (using (self (buffer-help output: #f shown: #f) : buffer-help)
    (defcommand (quit-help) "Kill *Help*; a view made for it closes."
      (let (b (live-help-buffer self))
        (if b
          (kill-buffer b)
          (message "No help is shown"))))
    (keymap-set "C-h q" 'quit-help)
    (defcommand (describe-advice) "Choose an advised function or command and show its advice, outermost first."
      (describe-advice!))
    (defcommand (describe-stylesheets) "List the page's stylesheets in order, with their owners, files and replacements, and check them."
      (describe-stylesheets!))
    (defcommand (reload-stylesheets) "Read every stylesheet's file again."
      (reload-stylesheets!))
    (context-defer! ctx (lambda ()
                          (let (b (live-help-buffer self))
                            (when b (kill-buffer b)))))
    (context-provide! ctx help-service (Help self))))
