(import :std/error
        :std/test
        :tuna/kernel
        :tuna/services/text-store
        :tuna/services/buffers
        :tuna/plugins/rope
        :tuna/plugins/string-text-store
        :tuna/plugins/buffers)
(export buffers-test)

(def (with-buffers thunk)
  (parameterize ((current-kernel (new-kernel)))
    (activate-plugin! rope-text-store-plugin)
    (activate-plugin! buffers-plugin)
    (thunk)))

(def (raises? thunk)
  (with-catch (lambda (e) #t) (lambda () (thunk) #f)))

(def buffers-test
  (test-suite "tuna/services/buffers"
    (test-case "*scratch* is a tree holding one empty text node"
      (with-buffers
       (lambda ()
         (check (buffer-name (current-buffer)) => "*scratch*")
         (check (text-node? (buffer-root (current-buffer))) => #t)
         (check (eq? (current-text-node) (buffer-root (current-buffer))) => #t)
         (check (point) => 1)
         (check (point-max) => 1))))

    (test-case "positions count characters from 1; lines from 1, columns from 0"
      (with-buffers
       (lambda ()
         (let (t (current-text))
           ;; h é l l o _ 😀 | \n | w ö r l d
           (insert "héllo 😀\nwörld")
           (check (point) => 14)
           (check (point-max) => 14)
           (check (text-substring t 7 8) => "😀")
           (check (text-line-count t) => 2)
           (check (text-line-at t 8) => 1)
           (check (text-line-at t 9) => 2)
           (check (text-line-start t 2) => 9)
           (check (text-line-end t 1) => 8)
           (check (text-line-end t 2) => 14)
           (check (text-column t 7) => 6)
           (check (text-column t 11) => 2)
           (check (text-position-at t 2 3) => 12)
           (check (text-position-at t 1 100) => 8)
           (check (raises? (lambda () (text-substring t 0 1))) => #t)
           (check (raises? (lambda () (text-substring t 1 15))) => #t)
           (check (raises? (lambda () (text-line-start t 3))) => #t)
           (goto-char 100)
           (check (point) => 14)
           (goto-char 0)
           (check (point) => 1)))))

    (test-case "undo removes one group at a time; undoing after a break redoes"
      (with-buffers
       (lambda ()
         (let (t (current-text))
           (insert "a")
           (insert "b")
           (undo-boundary! t)
           (insert "c")
           (check (text-undo! t #f) => 3)
           (check (text-string t) => "ab")
           (check (text-undo! t #t) => 1)
           (check (text-string t) => "")
           (check (raises? (lambda () (text-undo! t #t))) => #t)
           (text-undo! t #f)
           (check (text-string t) => "ab")))))

    (test-case "points relocate through changes made elsewhere"
      (with-buffers
       (lambda ()
         (let (t (current-text))
           (insert "hello world")
           (goto-char 7)
           (text-replace! t 1 1 "XX")
           (check (point) => 9)
           (text-replace! t 1 3 "")
           (check (point) => 7)
           (text-replace! t 5 9 "")
           (check (point) => 5)
           (check (text-string t) => "hellrld")))))

    (test-case "swapping the text store live keeps every text and point"
      (with-buffers
       (lambda ()
         (defplugin (adds-other ctx)
           "Adds a second buffer."
           (context-add-buffer! ctx (new-buffer "other" (new-text-node (new-text "second ☃ buffer")))))
         (activate-plugin! adds-other)
         (let ((other (get-buffer "other"))
               (t (current-text)))
           (insert "hello\nwörld 😀")
           (goto-char 4)
           (check (string? (text-snapshot t)) => #f)
           (activate-plugin! string-text-store-plugin)
           (check (eq? (service-provider text-store-service) string-text-store) => #t)
           (check (text-string t) => "hello\nwörld 😀")
           (check (string? (text-snapshot t)) => #t)
           (check (point) => 4)
           (undo-boundary! t)
           (insert "p")
           (check (text-string t) => "helplo\nwörld 😀")
           (check (text-string (text-node-content (buffer-root other))) => "second ☃ buffer")
           (deactivate-plugin! string-text-store-plugin)
           (check (string? (text-snapshot t)) => #f)
           (check (text-string t) => "helplo\nwörld 😀")
           (check (point) => 5)
           (text-undo! t #f)
           (check (text-string t) => "hello\nwörld 😀")))))

    (test-case "node kinds come and go with their plugin; projections need no renderer"
      (with-buffers
       (lambda ()
         (defplugin (box-kind ctx)
           "Defines the box node kind."
           (context-define-node-kind! ctx 'box doc: "A box."
                                      project: (lambda (n) (node-attribute n 'label))))
         (let (tree (new-node 'column
                              children: [(new-node 'box attributes: [['label . "Box"]])
                                         (new-text-node (new-text "text"))]))
           (check (node-kind-ref 'box) => #f)
           (activate-plugin! box-kind)
           (check (node-kind-info-name (node-kind-ref 'box)) => 'box)
           (check (node-text-projection tree) => "Box\ntext")
           (check (text-node? (first-text-node tree)) => #t)
           (deactivate-plugin! box-kind)
           (check (node-kind-ref 'box) => #f)
           (check (node-text-projection tree) => "\ntext")))))))
