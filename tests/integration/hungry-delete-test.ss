#lang :tuna/prelude
;;; Hungry deletion through real Commands, Keys, Buffers and basic editing.
(import :std/test
        :std/error
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/hungry-delete/plugin
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        (only-in "../../tuna/tests/support/string-input" test-messages current-message))
(export hungry-delete-test)

(def hungry-plugins
  [commands keys test-messages rope-text-store settings buffers basic-editing hungry-delete])

(def (state) => :list
  (call-on-editor-loop
   (lambda () [(text-string (current-text)) (point) (current-message)])))

(def (show-text! (contents : :string)) => :void
  (let (b (new-buffer "test" (new-text-node (new-text contents))))
    (add-buffer! b)
    (switch-to-buffer b)
    (goto-char (point-max))))

(def (hungry-layers) => :list
  (advice-target-info-advice (advice-for (command delete-backward-char))))

(def hungry-delete-test
  (test-suite "tuna/integration/hungry-delete"
    (test-case "a run before point is one edit and one undo restores text and point"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (show-text! "a   z")
         (goto-char 5)
         (let (revision (text-chars-revision (current-text)))
           (start-editor-loop!)
           (type! "DEL")
           (check (state) => ["az" 2 ""])
           (call-on-editor-loop
            (lambda ()
              (check (text-chars-revision (current-text)) => (fx1+ revision))))
           (type! "C-/")
           (check (state) => ["a   z" 5 "Undo"])))))

    (test-case "only the selected view's focused text node changes"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (let* ((first (new-text "first   "))
                (focused (new-text "a   "))
                (leaf (new-text-node focused))
                (b (new-buffer "tree" (new-node 'column children: [(new-text-node first) leaf]))))
           (add-buffer! b)
           (set-selected-view! (new-view-at b leaf 5 (text-chars-revision focused)))
           (start-editor-loop!)
           (type! "DEL")
           (check (state) => ["a" 2 ""])
           (call-on-editor-loop (lambda () (check (text-string first) => "first   ")))))))

    (test-case "single spaces and runs stop at literal non-space boundaries"
      (for-each
       (lambda ((example : :pair))
         (call-with-fresh-kernel hungry-plugins
          (lambda ()
            (show-text! (car example))
            (start-editor-loop!)
            (type! "DEL")
            (check (state) => [(cadr example) (fx1+ (string-length (cadr example))) ""]))))
       '(("a " "a") ("   " "") ("a\t  " "a\t")
         ("a\n  " "a\n") ("a\u00a0  " "a\u00a0"))))

    (test-case "non-spaces fall through to ordinary one-character deletion"
      (for-each
       (lambda ((contents : :string))
         (call-with-fresh-kernel hungry-plugins
          (lambda ()
            (show-text! contents)
            (start-editor-loop!)
            (type! "DEL")
            (check (state) => ["a" 2 ""]))))
       ["ab" "a\t" "a\n" "a\u00a0"]))

    (test-case "beginning and no-text errors are the original errors"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (for-each
          (lambda ((prepare : :procedure))
            (prepare)
            (deactivate-plugin! hungry-delete)
            (let (ordinary (with-catch values (lambda () (call-command 'delete-backward-char))))
              (activate-plugin! hungry-delete)
              (let (advised (with-catch values (lambda () (call-command 'delete-backward-char))))
                (check (Error? ordinary) => #t)
                (check (Error? advised) => #t)
                (check (advice-error? advised) => #f)
                (check (Error-message advised) => (Error-message ordinary)))))
          [(lambda () (goto-char (point-min)))
           (lambda ()
             (let (b (new-buffer "rich" (new-node 'label)))
               (add-buffer! b)
               (switch-to-buffer b)
               (check (current-text-node) => #f)))]))))

    (test-case "owner deactivation restores one-character Backspace"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (show-text! "a   ")
         (start-editor-loop!)
         (call-on-editor-loop (lambda () (deactivate-plugin! hungry-delete)))
         (type! "DEL")
         (check (state) => ["a  " 4 ""])
         (call-on-editor-loop
          (lambda ()
            (check (hungry-layers) => [])
            (activate-plugin! hungry-delete)))
         (type! "DEL")
         (check (state) => ["a" 2 ""]))))

    (test-case "the owned layer remains while basic editing disappears and returns"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (show-text! "a   ")
         (let (identity (advice-target-info-identity (advice-for (command delete-backward-char))))
           (deactivate-plugin! basic-editing)
           (check (plugin-active? hungry-delete) => #t)
           (check (command-entry 'delete-backward-char) => #f)
           (check (map advice-info-name (hungry-layers)) => '(hungry))
           (activate-plugin! basic-editing)
           (check (eq? identity (advice-target-info-identity (advice-for (command delete-backward-char)))) => #t)
           (check (map advice-info-owner (hungry-layers)) => '(hungry-delete))
           (start-editor-loop!)
           (type! "DEL")
           (check (state) => ["a" 2 ""])))))

    (test-case "replacement bases keep their return values and exception identity on fallback"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (let (failure (Error "original failure"))
           (defplugin (replacement ctx) "An ordinary replacement command." requires: [commands-service]
             (context-define-command! ctx 'delete-backward-char (lambda () (values 'one 'two))))
           (activate-plugin! replacement order: 100)
           (check (call-with-values (lambda () (call-command 'delete-backward-char)) list) => '(one two))
           (deactivate-plugin! replacement)
           (defplugin (failing ctx) "A command that raises the original exception." requires: [commands-service]
             (context-define-command! ctx 'delete-backward-char (lambda () (raise failure))))
           (activate-plugin! failing order: 100)
           (check (eq? failure (with-catch values (lambda () (call-command 'delete-backward-char)))) => #t)))))))
