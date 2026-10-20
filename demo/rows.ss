;;; The rows demo plugin, for development only (`tuna --config
;;; demo/init.ss`): C-c G shows *rows*, a buffer of 10,000 row nodes, each
;;; a label and one item, under a node opening into its children. It
;;; scrolls by the same machinery as *long*'s 50,000 lines (C-c g), which
;;; shows that a view's scrolling knows items, not lines.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/stylesheets/contract)
(export rows-demo)

(def rows-buffer-name "*rows*")
(def rows-count 10000)

;; A row's label: its number, and every seventh row a second line, so rows
;; differ in height.
(def (row-label (number : :fixnum)) => :string
  (string-append "Row " (number->string number)
                 (if (zero? (modulo number 7)) "\nwith a second line" "")))

(def (rows-buffer) => buffer
  (new-buffer rows-buffer-name
              (new-node 'rows
                        children: (let lp ((number rows-count) (out []))
                                    (if (fx< number 1)
                                      out
                                      (lp (fx1- number)
                                          (cons (new-node 'row attributes: [(cons 'label (row-label number))])
                                                out)))))))

(defplugin (rows-demo ctx)
  "C-c G: *rows*, a buffer of 10,000 row nodes, for trying scrolling on items that are not lines."
  requires: [commands-service input-service buffers-service layout-service]
  (add-stylesheet 'rules "rows.css")
  (context-define-node-kind! ctx 'rows doc: "Rows, one under another." items: 'children)
  (context-define-node-kind! ctx 'row doc: "One row: a label." items: 'whole
                             project: (lambda (n) (node-attribute n 'label)))
  (context-define-node-renderer! ctx 'rows (lambda (n children) `(div (@ (class "rows")) ,@children)))
  (context-define-node-renderer! ctx 'row
                                 (lambda (n children) `(div (@ (class "row")) ,(node-attribute n 'label))))
  (define-command ctx (rows-buffer) "Show *rows*, 10,000 row nodes, making it the first time."
    (let (b (or (get-buffer rows-buffer-name)
                (let (b (rows-buffer))
                  (context-add-buffer! ctx b)
                  b)))
      (set-view-buffer (selected-view) b)))
  (keymap-set ctx "C-c G" 'rows-buffer))
