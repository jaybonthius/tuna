;;; The demo's minibuffer rename, slow digit highlighter, and
;;; describe-services, driven through the real editor loop.
(import :std/sync/completion
        :std/test
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/help
        :tuna/services/settings
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/single-window
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session")
(export demo-test)

(def demo-plugins
  [keys-plugin echo-area-plugin help-panel-plugin rope-text-store-plugin
   settings-plugin no-session-plugin buffers-plugin single-window-plugin html-renderer-plugin
   basic-editing-plugin
   minibuffer-plugin demo-plugin])

(def jobs #f)

(defplugin (job-host-plugin ctx)
  "Lends a job group to the tests."
  (set! jobs (new-job-group ctx)))

(def editing-plugins
  [keys-plugin echo-area-plugin rope-text-store-plugin settings-plugin
   buffers-plugin basic-editing-plugin job-host-plugin])

(def (on-baton thunk) (call-on-editor-loop thunk))

(def (screen)
  (on-baton (lambda () (Renderer-render-screen (Renderer (service-provider renderer-service))))))

(def (contains? html needle)
  (and (string-contains html needle) #t))

;; The characters under the current text's digit highlights.
(def (highlighted)
  (on-baton
   (lambda ()
     (let (t (current-text))
       (map (lambda (s) (text-substring t (span-start s) (span-end s)))
            (text-highlights t 'digits))))))

(def demo-test
  (test-suite "tuna/plugins/demo"
    (test-case "C-c r renames the current buffer through the minibuffer"
      (call-with-fresh-kernel demo-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "r" "n" "o" "t" "e" "s")
         (let (html (screen))
           (check (contains? html "<span class=\"prompt\">New name: </span>") => #t)
           (check (contains? html "notes<span class=\"cursor\"> </span>") => #t)
           (check (contains? html "Tuna · *scratch*") => #t))
         (type! "RET")
         (check (on-baton (lambda () (buffer-name (current-buffer)))) => "notes")
         (let (html (screen))
           (check (contains? html "class=\"minibuffer\"") => #f)
           (check (contains? html "Tuna · notes") => #t)
           (check (contains? html "Renamed to notes") => #t)))))

    (test-case "C-g abandons the rename prompt"
      (call-with-fresh-kernel demo-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "r" "x")
         (check (contains? (screen) "New name: ") => #t)
         (type! "C-g")
         (let (html (screen))
           (check (contains? html "class=\"minibuffer\"") => #f)
           (check (contains? html "Tuna · *scratch*") => #t)
           (check (contains? html ">Quit<") => #t)))))

    (test-case "C-h s shows buffers adapting to the text store"
      (call-with-fresh-kernel demo-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-h" "s")
         (check (on-baton (lambda () (help-output-lines (current-help))))
                ? (cut member
                       "text-store (live)  provider: rope-text-store-plugin  dependents: buffers-plugin (adapts)"
                       <>)))))

    (test-case "the slow highlighter colors digits shortly after typing"
      (call-with-fresh-kernel demo-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "1" "2" "b" "3")
         (check (wait-until (lambda () (equal? (highlighted) ["12" "3"]))) => #t)
         (check (contains? (screen) "a<span class=\"face-digit\">12</span>b") => #t)
         ;; Typing continues: the colors follow.
         (type! "C-a" "x" "4")
         (check (wait-until (lambda () (equal? (highlighted) ["4" "12" "3"]))) => #t))))

    (test-case "the slow highlighter leaves the minibuffer's text alone"
      (call-with-fresh-kernel demo-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "r" "1" "2")
         (thread-sleep! (* 2 (on-baton (lambda () (setting-value digit-highlight-delay)))))
         (check (on-baton (lambda () (text-string (current-text)))) => "12")
         (check (highlighted) => [])
         (type! "C-g" "3")
         (check (wait-until (lambda () (equal? (highlighted) ["3"]))) => #t))))

    (test-case "rebased digit highlights land on the right characters after edits made while the job ran"
      (call-with-fresh-kernel editing-plugins
       (lambda ()
         (start-editor-loop!)
         (let (gate (make-completion))
           (type! "a" "1" "2" "b" "3" "4")
           (on-baton
            (lambda ()
              (let (t (current-text))
                (job-group-start! jobs 'gated-digits
                                  input: (text-snapshot t)
                                  run: (lambda (snapshot) (completion-wait! gate) (digit-spans snapshot))
                                  apply: (lambda (spans) (set-highlights! t 'digits spans))
                                  target: t
                                  validity: 'rebase))))
           ;; While the job runs: type before everything, and delete the b.
           (type! "C-a" "Z" "C-f" "C-f" "C-f" "C-d")
           (check (on-baton (lambda () (text-string (current-text)))) => "Za1234")
           (completion-post! gate #t)
           (check (wait-until (lambda () (pair? (highlighted)))) => #t)
           (check (highlighted) => ["12" "34"])))))))
