;;; Program status reported for any buffer, as a chat reports its agent's:
;;; report-program-status! shows the record in the buffer's status line,
;;; runs program-status-change-hook with the buffer, and the
;;; notifications plugin says so when the buffer is out of sight.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        (only-in :tuna/plugins/renderer/contract status-line-text)
        :tuna/plugins/program-status/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/program-status/plugin
        :tuna/plugins/notifications/plugin
        "../../tuna/tests/support/kernel"
        "../../tuna/tests/support/string-input")
(export program-status-test)

(def changes [])

(defplugin (change-recorder ctx)
  "Records what program-status-change-hook runs with: buffer name, id, old state, new state."
  requires: [buffers-service]
  optional: [program-status-service]
  (context-add-hook! ctx program-status-change-hook 'test
                     (lambda ((b : buffer) (id : :string) (old :? program-status-report) (new :? program-status-report))
                       (set! changes (cons [(buffer-name b) id
                                            (and old (program-status-report-state old))
                                            (and new (program-status-report-state new))]
                                           changes)))))

(def program-status-plugins
  [commands keys test-messages rope-text-store settings buffers program-status notifications change-recorder])

(def (report (state : :symbol) kind: (kind #f) message: (message #f)) => program-status-report
  (make-program-status-report "" state kind #f "pi" #f message))

(def program-status-test
  (test-suite "tests/integration: program status for any buffer"
    (test-case "a report shows in the buffer's status line, runs the change hook with the buffer, and notifies out of sight"
      (set! changes [])
      (call-with-fresh-kernel program-status-plugins
       (lambda ()
         (start-editor-loop!)
         (call-on-editor-loop
          (lambda ()
            (let ((chat (new-buffer "chat" (new-text-node (new-text ""))))
                  (other (new-buffer "other" (new-text-node (new-text "")))))
              (add-buffer! chat)
              (add-buffer! other)
              (switch-to-buffer chat)
              (report-program-status! chat (report 'blocked kind: 'question))
              (check (string-contains (status-line-text (selected-view) #f) "[pi: blocked: question]") ? values)
              ;; Looked at: no notification.
              (check (current-message) => "")
              (switch-to-buffer other)
              (report-program-status! chat (report 'done message: "all done"))
              (check (current-message) => "pi: all done")
              (check (string-contains (status-line-text (selected-view) #f) "[") => #f)
              (check (reverse changes) => [["chat" "" #f 'blocked] ["chat" "" 'blocked 'done]])))))))))
