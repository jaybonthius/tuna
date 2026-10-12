;;; Prompts driven by key events through the real editor loop.
(import :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/settings
        :tuna/services/minibuffer
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer)
(export minibuffer-test)

(include "test-keys.ss")

(defsetting case-fold-search #t "Whether searches ignore case.")

(def answers [])
(def quit? #f)
(def seen-by-other #f)
(def seen-after-wait #f)

(defplugin (asking ctx)
  "Commands that ask questions."
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

(def (with-minibuffer thunk)
  (set! answers [])
  (set! quit? #f)
  (call-with-editor [keys-plugin echo-area-plugin rope-text-store-plugin settings-plugin
                     buffers-plugin basic-editing-plugin minibuffer-plugin asking]
                    thunk))

;; Once every key sent so far has run: the window's buffer text, the
;; innermost prompt's question and answer so far (or #f), and the message.
(def (state)
  (call-on-editor-loop
   (lambda ()
     (let (prompt (active-prompt))
       [(text-string (text-node-content (first-text-node (buffer-root (view-showing (window-view))))))
        (and prompt [(prompt-display-question prompt)
                     (text-string (text-node-content (prompt-display-node prompt)))])
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
         (check (current-command-name) => #f)
         (check answers => [])
         (type! "RET")
         (check (state) => ["x" #f ""])
         (check answers => ["new"])
         (check (minibuffer-buffers) => [])
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
         (check (minibuffer-buffers) => []))))

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
         (check (minibuffer-buffers) => []))))))
