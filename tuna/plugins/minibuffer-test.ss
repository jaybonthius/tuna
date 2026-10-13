;;; Prompts driven by key events through the real editor loop: each
;;; prompt is a buffer, question and answer, shown in the minibuffer view
;;; nearest the selected view, which is selected while it waits.
(import :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/settings
        :tuna/services/minibuffer
        :tuna/services/layout
        :tuna/plugins/keys
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        :tuna/plugins/minibuffer
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session"
        (only-in "../test-support/string-input" test-messages-plugin current-message))
(export minibuffer-test)

(defsetting case-fold-search #t "Whether searches ignore case.")

(def answers [])
(def quit? #f)
(def seen-by-other #f)
(def seen-after-wait #f)

(defplugin (asking ctx)
  "Commands that ask questions."
  requires: [input-service]
  (define-command ctx (ask) "Ask a name."
    (with-catch (lambda (e) (set! quit? (quit-condition? e)) (raise e))
                (lambda () (set! answers (cons (read-string "Name: ") answers)))))
  (define-command ctx (ask-with-setting) "Bind a setting, then ask."
    (with-settings ((case-fold-search #f))
      (set! answers (cons (read-string "Search: ") answers))
      (set! seen-after-wait (setting-value case-fold-search))))
  (define-command ctx (read-setting) "Note the setting's value."
    (set! seen-by-other (setting-value case-fold-search)))
  (keymap-set ctx "C-c a" 'ask)
  (keymap-set ctx "C-c w" 'ask-with-setting)
  (keymap-set ctx "C-c v" 'read-setting))

;; Typing and deleting a character, standing in for basic editing so that
;; answers can be typed into a prompt.
(defplugin (typing ctx)
  "Inserts printing characters; DEL deletes the character before point."
  requires: [input-service buffers-service]
  (define-command ctx (self-insert-command) "Insert the character typed."
    (insert (key-event-key (last-command-event))))
  (define-command ctx (delete-backward-char) "Delete the character before point."
    (delete-region (fx1- (point)) (point)))
  (keymap-set ctx printing-char-key 'self-insert-command)
  (keymap-set ctx "DEL" 'delete-backward-char))

(def (with-minibuffer thunk)
  (set! answers [])
  (set! quit? #f)
  (call-with-fresh-kernel [keys-plugin test-messages-plugin rope-text-store-plugin settings-plugin
                           no-session-plugin buffers-plugin layout-plugin typing minibuffer-plugin asking]
    (lambda ()
      (start-editor-loop!)
      (thunk))))

;; The selected view, and what it shows: the question of a prompt's
;; buffer, or the buffer's name.
(def (selected-shows)
  (call-on-editor-loop
   (lambda ()
     (let* ((v (selected-view))
            (root (buffer-root (view-showing v))))
       (if (and (minibuffer-view? v) (pair? (node-children root)))
         ['question (node-attribute (car (node-children root)) 'content)]
         (buffer-name (view-showing v)))))))

(def (bar-shows)
  (call-on-editor-loop
   (lambda () (map (lambda (v) (buffer-name (view-showing v))) (filter minibuffer-view? (view-list))))))

;; Once every key sent so far has run: *scratch*'s text, the innermost
;; prompt's question and answer so far (or #f), and the message.
(def (state)
  (call-on-editor-loop
   (lambda ()
     (let (prompt (active-prompt))
       [(text-string (text-node-content (buffer-root (get-buffer "*scratch*"))))
        (and prompt [(prompt-display-question prompt)
                     (text-string (text-node-content (prompt-display-answer prompt)))])
        (current-message)]))))

(def (minibuffer-buffers)
  (call-on-editor-loop
   (lambda ()
     (filter (lambda (name) (string-prefix? " *Minibuf" name)) (map buffer-name (buffer-list))))))

(def minibuffer-test
  (test-suite "tuna/plugins/minibuffer"
    (test-case "a prompt suspends its command while the editor keeps dispatching keys"
      (with-minibuffer
       (lambda ()
         (type! "x" "C-c" "a" "n" "o" "DEL" "e" "w")
         (check (state) => ["x" ["Name: " "new"] ""])
         (check (current-task-name) => #f)
         (check answers => [])
         (type! "RET")
         (check (state) => ["x" #f ""])
         (check answers => ["new"])
         (check (minibuffer-buffers) => [" *Minibuf-0*"])
         ;; Typing goes to the buffer again.
         (type! "y")
         (check (state) => ["xy" #f ""]))))

    (test-case "C-g abandons the prompt and the waiting command receives quit"
      (with-minibuffer
       (lambda ()
         (type! "C-c" "a" "z")
         ;; A quit key that arrives while the command still runs quits the
         ;; command itself (ADR 3), so wait until it waits at the prompt.
         (check (state) => ["" ["Name: " "z"] ""])
         (type! "C-g")
         (check (state) => ["" #f "Quit"])
         (check quit? => #t)
         (check answers => [])
         (check (minibuffer-buffers) => [" *Minibuf-0*"]))))

    (test-case "nested prompts are answered innermost first"
      (with-minibuffer
       (lambda ()
         (type! "C-c" "a" "o" "u" "t")
         (type! "C-c" "a" "i" "n")
         (check (state) => ["" ["Name: " "in"] ""])
         (type! "RET")
         (check (state) => ["" ["Name: " "out"] ""])
         (check answers => ["in"])
         (type! "!" "RET")
         (check (state) => ["" #f ""])
         (check answers => ["out!" "in"]))))

    (test-case "a with-settings binding is invisible to another command while its command waits"
      (with-minibuffer
       (lambda ()
         (set! seen-by-other 'unset)
         (set! seen-after-wait 'unset)
         (type! "C-c" "w" "q")
         (type! "C-c" "v")
         (check (state) => ["" ["Search: " "q"] ""])
         (check seen-by-other => #t)
         (type! "RET")
         (check (state) => ["" #f ""])
         (check answers => ["q"])
         (check seen-after-wait => #f))))

    (test-case "turning the minibuffer off abandons waiting prompts"
      (with-minibuffer
       (lambda ()
         (type! "C-c" "a" "z")
         (check (state) => ["" ["Name: " "z"] ""])
         (call-on-editor-loop (lambda () (deactivate-plugin! minibuffer-plugin)))
         (check (wait-until (lambda () quit?)) => #t)
         (check (state) => ["" #f "Quit"])
         (check (minibuffer-buffers) => []))))

    (test-case "a prompt is a buffer in the bar's view, selected while it waits; the selection comes back"
      (with-minibuffer
       (lambda ()
         (check (bar-shows) => [" *Minibuf-0*"])
         (check (selected-shows) => "*scratch*")
         (type! "C-c" "a")
         (check (state) => ["" ["Name: " ""] ""])
         (check (selected-shows) => ['question "Name: "])
         (check (length (bar-shows)) => 1)
         ;; Typing goes to the answer, in the prompt's buffer.
         (type! "o" "k")
         (check (state) => ["" ["Name: " "ok"] ""])
         (check (call-on-editor-loop (lambda () (text-string (current-text)))) => "ok")
         ;; Nested: the inner prompt shows in the same view, then the outer again.
         (type! "C-c" "a")
         (check (selected-shows) => ['question "Name: "])
         (check (state) => ["" ["Name: " ""] ""])
         (type! "RET")
         (check (state) => ["" ["Name: " "ok"] ""])
         (check (selected-shows) => ['question "Name: "])
         (type! "RET")
         (check (selected-shows) => "*scratch*")
         (check answers => ["ok" ""])
         (check (bar-shows) => [" *Minibuf-0*"]))))

    (test-case "a minibuffer pinned inside a split catches the questions asked from that split"
      (with-minibuffer
       (lambda ()
         ;; left | (right / its own minibuffer, pinned), and the bar.
         (call-on-editor-loop
          (lambda ()
            (let* ((left (selected-view))
                   (right (split-view left 'right))
                   (own (split-view right 'below))
                   (b (new-buffer " *own minibuffer*" (new-node minibuffer-node-kind))))
              (add-buffer! b)
              (set-view-buffer own b)
              (select-view own))))
         (type! "C-x" "w" "p")
         (call-on-editor-loop (lambda () (select-view (cadr (view-list)))))
         (type! "C-c" "a")
         (check (selected-shows) => ['question "Name: "])
         ;; The split's own minibuffer view asks; the bar's stays idle.
         (check (cdr (bar-shows)) => [" *Minibuf-0*"])
         (check (call-on-editor-loop (lambda () (eq? (selected-view) (caddr (view-list))))) => #t)
         (type! "RET")
         (check (bar-shows) => [" *own minibuffer*" " *Minibuf-0*"])
         (check (call-on-editor-loop (lambda () (eq? (selected-view) (cadr (view-list))))) => #t)
         ;; From the left half the split's minibuffer is not pinned beside the
         ;; way up: the question goes to the bar.
         (call-on-editor-loop (lambda () (select-view (car (view-list)))))
         (type! "C-c" "a")
         (check (call-on-editor-loop (lambda () (eq? (selected-view) (cadddr (view-list))))) => #t)
         (type! "C-g")
         (check (call-on-editor-loop (lambda () (eq? (selected-view) (car (view-list))))) => #t))))))
