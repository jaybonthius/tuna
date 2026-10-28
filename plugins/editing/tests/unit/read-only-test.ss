;;; Read-only nodes through the editing commands and the real editor loop:
;;; text under a node whose `read-only` attribute is true can be moved
;;; through, selected and copied, but no editing command changes it, while
;;; an editable text beside it in the same buffer can be edited, and the
;;; plugin that owns the buffer still changes the read-only text with
;;; text-replace!.
(import :std/test
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/editing/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/editing/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message))
(export read-only-test)

(defplugin (deleting-selection ctx)
  "Turns delete-selection on."
  requires: [settings-service]
  (context-set-setting! ctx delete-selection #t))

(def read-only-plugins
  [commands keys test-messages rope-text-store settings buffers editing deleting-selection])

;; Show a buffer like a chat's: a read-only transcript node holding a
;; text node, then an editable prompt text node; focus the transcript's
;; text. Returns the transcript node and the two text nodes.
(def (chat-buffer!)
  (call-on-editor-loop
   (lambda ()
     (let* ((reply (new-text-node (new-text "the reply text")))
            (transcript (new-node 'transcript attributes: [(cons 'read-only #t)] children: [reply]))
            (prompt (new-text-node (new-text "ask")))
            (b (new-buffer "chat" (new-node 'chat children: [transcript prompt]))))
       (add-buffer! b)
       (switch-to-buffer b)
       (set-view-focus! (selected-view) reply 1)
       [transcript reply prompt]))))

;; The message, once every key sent so far has run.
(def (message-now)
  (call-on-editor-loop current-message))

(def (text-of n)
  (call-on-editor-loop (lambda () (text-string (text-node-content n)))))

;; Point, the region's ends when active, and the message.
(def (state)
  (call-on-editor-loop
   (lambda ()
     [(point) (and (region-active?) [(region-beginning) (region-end)]) (current-message)])))

(def read-only-test
  (test-suite "tuna/plugins/editing: read-only nodes"
    (test-case "a node's read-only attribute covers the text nodes under it"
      (call-with-fresh-kernel read-only-plugins
       (lambda ()
         (start-editor-loop!)
         (match (chat-buffer!)
           ([transcript reply prompt]
            (check (call-on-editor-loop (lambda () [(node-read-only? transcript) (node-read-only? reply)
                                                    (node-read-only? prompt)]))
                   => [#t #t #f])
            (call-on-editor-loop (lambda () (set-node-attribute! transcript 'read-only #f)))
            (check (call-on-editor-loop (lambda () (node-read-only? reply))) => #f))))))

    (test-case "editing commands leave read-only text alone; moving, selecting and copying work"
      (call-with-fresh-kernel read-only-plugins
       (lambda ()
         (start-editor-loop!)
         (match (chat-buffer!)
           ([transcript reply prompt]
            (type! "C-f" "C-f" "C-f" "C-f")
            (check (state) => [5 #f ""])
            (type! "x")
            (check (state) => [5 #f "Text is read-only"])
            (for-each (lambda (key)
                        (type! "C-g" key)
                        (check (message-now) => "Text is read-only"))
                      ["RET" "DEL" "C-d" "M-d" "M-DEL" "M-t" "M-u" "C-/"])
            (paste "pasted")
            (check (text-of reply) => "the reply text")
            ;; Selecting and copying.
            (type! "C-g" "C-SPC" "M-f")
            (check (take (state) 2) => [10 [5 10]])
            (type! "M-w")
            (check (call-on-editor-loop (lambda () (current-kill 0))) => "reply")
            ;; Typing over a selection with delete-selection on deletes nothing.
            (type! "C-SPC" "M-b" "x")
            (check (text-of reply) => "the reply text")
            ;; Killing copies, as Emacs does, but deletes nothing.
            (type! "C-g" "C-a" "C-SPC" "M-f" "C-w")
            (check (call-on-editor-loop (lambda () (current-kill 0))) => "the")
            (check (message-now) => "Text is read-only")
            (type! "C-g" "C-y")
            (check (text-of reply) => "the reply text"))))))

    (test-case "the editable text beside it is edited and undone; the owner still writes the read-only text"
      (call-with-fresh-kernel read-only-plugins
       (lambda ()
         (start-editor-loop!)
         (match (chat-buffer!)
           ([transcript reply prompt]
            (call-on-editor-loop (lambda () (set-view-focus! (selected-view) prompt 4)))
            (type! "!" "?")
            (check (text-of prompt) => "ask!?")
            (type! "C-/")
            (check (text-of prompt) => "ask")
            (call-on-editor-loop
             (lambda ()
               (let (t (text-node-content reply))
                 (text-replace! t (fx1+ (text-size t)) (fx1+ (text-size t)) ", streamed"))))
            (check (text-of reply) => "the reply text, streamed")
            ;; The buffer's own read-only setting still says so first.
            (call-on-editor-loop (lambda () (set-buffer-setting! (current-buffer) buffer-read-only #t)))
            (type! "x")
            (check (text-of prompt) => "ask")
            (check (string-prefix? "Buffer is read-only" (message-now)) => #t))))))))
