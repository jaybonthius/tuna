;;; Prompts driven by key events through the real editor loop: each
;;; prompt is a buffer, question and answer, shown in the minibuffer view
;;; nearest the selected view, which is selected while it waits.
(import :tuna/services/commands
        :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/settings
        :tuna/services/minibuffer
        :tuna/services/layout
        :tuna/plugins/commands
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
  requires: [commands-service input-service minibuffer-service settings-service]
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
  "Inserts printing characters and, on RET, a newline; DEL deletes the character before point."
  requires: [commands-service input-service buffers-service]
  (define-command ctx (self-insert-command) "Insert the character typed."
    (insert (key-event-key (last-command-event))))
  (define-command ctx (delete-backward-char) "Delete the character before point."
    (delete-region (fx1- (point)) (point)))
  (define-command ctx (newline) "Insert a newline."
    (insert "\n"))
  (keymap-set ctx printing-char-key 'self-insert-command)
  (keymap-set ctx "DEL" 'delete-backward-char)
  (keymap-set ctx "RET" 'newline))

(def (with-minibuffer thunk)
  (set! answers [])
  (set! quit? #f)
  (call-with-fresh-kernel [commands-plugin keys-plugin test-messages-plugin rope-text-store-plugin settings-plugin
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

;; Select the view showing the buffer named NAME, or else the minibuffer
;; view showing a prompt.
(def (select-showing! name)
  (call-on-editor-loop
   (lambda ()
     (select-view (find (lambda (v)
                          (if name
                            (equal? (buffer-name (view-showing v)) name)
                            (and (minibuffer-view? v) (pair? (node-children (buffer-root (view-showing v)))))))
                        (view-list))))))

(def (minibuffer-buffers)
  (call-on-editor-loop
   (lambda ()
     (filter (lambda (name) (string-prefix? " *Minibuf" name)) (map buffer-name (buffer-list))))))

(def minibuffer-test
  (test-suite "tuna/plugins/minibuffer"
    (test-case "turning the command's plugin off quits its waiting read, leaving the minibuffer"
      (with-minibuffer
        (lambda ()
          (type! "C-c" "a" "z")
          (check (state) => ["" ["Name: " "z"] ""])
          (call-on-editor-loop (lambda () (deactivate-plugin! asking)))
          (check (wait-until (lambda () quit?)) => #t)
          (check (state) => ["" #f "Quit"])
          (check answers => [])
          (check (plugin-active? minibuffer-plugin) => #t)
          (check (bar-shows) => [" *Minibuf-0*"]))))

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

    (test-case "turning the minibuffer off abandons waiting prompts and removes its view"
      (with-minibuffer
       (lambda ()
         ;; One prompt answered first, so its view has shown another buffer.
         (type! "C-c" "a" "RET")
         (check (state) => ["" #f ""])
         (type! "C-c" "a" "z")
         (check (state) => ["" ["Name: " "z"] ""])
         (call-on-editor-loop (lambda () (deactivate-plugin! minibuffer-plugin)))
         (check (wait-until (lambda () quit?)) => #t)
         (check (state) => ["" #f "Quit"])
         (check (minibuffer-buffers) => [])
         ;; Its locked view went with it, though a prompt had shown there.
         (check (bar-shows) => [])
         (check (call-on-editor-loop (lambda () (length (view-list)))) => 1))))

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

    (test-case "RET and C-g belong to the prompt's buffer: in another view they mean what they always do"
      (with-minibuffer
       (lambda ()
         (type! "C-c" "a" "o" "k")
         (check (state) => ["" ["Name: " "ok"] ""])
         ;; Away from the prompt RET is a newline, and the question waits.
         (select-showing! "*scratch*")
         (type! "x" "RET" "y")
         (check (state) => ["x\ny" ["Name: " "ok"] ""])
         ;; C-g there is keyboard-quit, as in Emacs: the question still waits.
         (type! "C-g")
         (check (state) => ["x\ny" ["Name: " "ok"] "Quit"])
         (check quit? => #f)
         ;; Back in the prompt, RET answers it.
         (select-showing! #f)
         (type! "RET")
         (check (state) => ["x\ny" #f ""])
         (check answers => ["ok"])
         (check (selected-shows) => "*scratch*"))))

    (test-case "nested prompts: C-g abandons the inner one, then the outer one"
      (with-minibuffer
       (lambda ()
         (type! "C-c" "a" "o")
         (type! "C-c" "a" "i")
         (check (state) => ["" ["Name: " "i"] ""])
         (type! "C-g")
         (check (state) => ["" ["Name: " "o"] "Quit"])
         (check quit? => #t)
         (set! quit? #f)
         (check (selected-shows) => ['question "Name: "])
         (type! "C-g")
         (check (state) => ["" #f "Quit"])
         (check quit? => #t)
         (check answers => [])
         (check (selected-shows) => "*scratch*")
         (check (minibuffer-buffers) => [" *Minibuf-0*"]))))

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
         (check (call-on-editor-loop (lambda () (eq? (selected-view) (car (view-list))))) => #t))))

    (test-case "only the innermost prompt is answered; C-g in an outer one abandons it and those inside"
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
         ;; The outer question in the split's minibuffer, the inner in the bar.
         (call-on-editor-loop (lambda () (select-view (cadr (view-list)))))
         (type! "C-c" "a" "o")
         (call-on-editor-loop (lambda () (select-view (car (view-list)))))
         (type! "C-c" "a" "i")
         (check (state) => ["" ["Name: " "i"] ""])
         ;; RET in the outer prompt refuses; both still wait.
         (call-on-editor-loop (lambda () (select-view (caddr (view-list)))))
         (type! "RET")
         (check (cadr (state)) => ["Name: " "i"])
         (check (and (string-contains (caddr (state)) "Not in the innermost minibuffer") #t) => #t)
         (check answers => [])
         ;; C-g there abandons both.
         (type! "C-g")
         (check (state) => ["" #f "Quit"])
         (check answers => [])
         (check quit? => #t)
         (check (minibuffer-buffers) => [" *Minibuf-0*"]))))))
