;;; Integration: the editor's real plugins with command fixtures from
;;; tuna/test-support/, driven by keys through the real editor loop: a
;;; minibuffer prompt (rename-buffer) and quitting it, describe-services in
;;; the *Help* buffer and closing it, and a slow job (the digit highlighter) whose results
;;; follow typing, are cancelled when its plugin turns off, and skip the
;;; minibuffer.
(import :std/sync/completion
        :std/test
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/plugins/renderer/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/echo-area/contract
        :tuna/plugins/help/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/help/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/minibuffer/plugin
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        "../../plugins/session/tests/support/session"
        "../support/rename-command"
        "../support/services-help"
        "../support/digit-highlighter")
(export editor-test)

(def editor-plugins
  [commands keys echo-area help-buffer rope-text-store
   settings no-session buffers layout html-renderer
   basic-editing minibuffer
   rename-command services-help digit-highlighter])

(def jobs #f)

(defplugin (job-host ctx)
  "Lends a job group to the tests."
  (set! jobs (new-job-group ctx)))

(def job-plugins
  [commands keys rope-text-store settings
   buffers basic-editing job-host])

(def (on-baton thunk) (call-on-editor-loop thunk))

(defplugin (slow-highlighter ctx)
  "Makes the digit highlighter sleep for five seconds."
  requires: [settings-service]
  (context-set-setting! ctx digit-highlight-delay 5))

(def job-results 0)                     ; job-result tasks started

(defplugin (job-result-counter ctx)
  "Counts job-result tasks."
  (context-add-hook! ctx task-started-hook 'count-job-results
                     (lambda (id name)
                       (when (eq? name 'job-result)
                         (set! job-results (fx1+ job-results))))))

(def (screen)
  (on-baton (lambda () (Renderer-render-screen (Renderer (service-provider renderer-service))))))

(def (contains? html needle)
  (and (string-contains html needle) #t))

;; On the baton, start a job that waits for GATE, then computes the current
;; text's digit spans and applies them with the rebase policy.
(def (start-gated-digits! gate)
  (on-baton
   (lambda ()
     (let (t (current-text))
       (job-group-start! jobs 'gated-digits
                         input: (text-snapshot t)
                         run: (lambda (snapshot cancelled?)
                                (completion-wait! gate)
                                (digit-spans snapshot))
                         apply: (lambda (spans) (set-highlights! t 'digits spans))
                         target: t
                         validity: 'rebase)))))

;; The characters under the current text's digit highlights.
(def (highlighted)
  (on-baton
   (lambda ()
     (let (t (current-text))
       (map (lambda (s) (text-substring t (span-start s) (span-end s)))
            (text-highlights t 'digits))))))

(def editor-test
  (test-suite "integration: prompts, help, and a slow job in the editor"
    (test-case "C-c r renames the current buffer through the minibuffer"
      (call-with-fresh-kernel editor-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "r" "n" "o" "t" "e" "s")
         (let (html (screen))
           (check (contains? html "class=\"prompt\">New name: </span>") => #t)
           (check (contains? html "notes<span class=\"cursor\"> </span>") => #t)
           ;; The view the question came from keeps its status line, its
           ;; cursor hollow while the prompt's view is selected.
           (check (contains? html "Tuna · *scratch*") => #t)
           (check (contains? html "class=\"inactive-cursor\"") => #t))
         (type! "RET")
         (check (on-baton (lambda () (buffer-name (current-buffer)))) => "notes")
         (let (html (screen))
           (check (contains? html "New name: ") => #f)
           (check (contains? html "Tuna · notes") => #t)
           (check (contains? html "Renamed to notes") => #t)))))

    (test-case "C-g abandons the rename prompt"
      (call-with-fresh-kernel editor-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "r" "x")
         (check (contains? (screen) "New name: ") => #t)
         (type! "C-g")
         (let (html (screen))
           (check (contains? html "New name: ") => #f)
           (check (contains? html "Tuna · *scratch*") => #t)
           (check (contains? html ">Quit<") => #t)))))

    (test-case "C-h s shows buffers depending on the text store, in *Help*; C-h q closes it"
      (call-with-fresh-kernel editor-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-h" "s")
         (check (on-baton (lambda () (help-output-lines (current-help))))
                ? (cut member
                       "text-store (live)  provider: rope-text-store  dependents: buffers"
                       <>))
         (let (html (screen))
           (check (contains? html ">Services</h1>") => #t)
           (check (contains? html "provider: rope-text-store  dependents: buffers") => #t)
           (check (contains? html "Tuna · *Help*") => #t))
         ;; The selected view stays where it was.
         (check (on-baton (lambda () (buffer-name (current-buffer)))) => "*scratch*")
         (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (view-list))))
                ? (cut member "*Help*" <>))
         (type! "C-h" "q")
         (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (view-list))))
                ? (lambda (names) (not (member "*Help*" names))))
         (check (contains? (screen) "Tuna · *Help*") => #f))))

    (test-case "the slow highlighter colors digits shortly after typing"
      (call-with-fresh-kernel editor-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "1" "2" "b" "3")
         (check (wait-until (lambda () (equal? (highlighted) ["12" "3"]))) => #t)
         (check (contains? (screen) "a<span class=\"face-digit\">12</span>b") => #t)
         ;; Typing continues: the colors follow.
         (type! "C-a" "x" "4")
         (check (wait-until (lambda () (equal? (highlighted) ["4" "12" "3"]))) => #t))))

    (test-case "deactivating the highlighter stops its sleeping job early, applying nothing"
      (set! job-results 0)
      (call-with-fresh-kernel (append editor-plugins [slow-highlighter job-result-counter])
       (lambda ()
         (start-editor-loop!)
         (type! "1")
         (thread-sleep! 0.1)
         (check job-results => 0)
         (on-baton (lambda () (deactivate-plugin! digit-highlighter)))
         ;; The job reports back well before its five-second sleep ends.
         (check (wait-until (lambda () (fx>= job-results 1))) => #t)
         (on-baton void)
         (check (highlighted) => []))))

    (test-case "the slow highlighter leaves the minibuffer's text alone"
      (call-with-fresh-kernel editor-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "r" "1" "2")
         (thread-sleep! (* 2 (on-baton (lambda () (setting-value digit-highlight-delay)))))
         (check (on-baton (lambda () (text-string (current-text)))) => "12")
         (check (highlighted) => [])
         (type! "C-g" "3")
         (check (wait-until (lambda () (equal? (highlighted) ["3"]))) => #t))))

    (test-case "rebased digit highlights land on the right characters after edits made while the job ran"
      (call-with-fresh-kernel job-plugins
       (lambda ()
         (start-editor-loop!)
         (let (gate (make-completion))
           (type! "a" "1" "2" "b" "3" "4")
           (start-gated-digits! gate)
           ;; While the job runs: type before everything, and delete the b.
           (type! "C-a" "Z" "C-f" "C-f" "C-f" "C-d")
           (check (on-baton (lambda () (text-string (current-text)))) => "Za1234")
           (completion-post! gate #t)
           (check (wait-until (lambda () (pair? (highlighted)))) => #t)
           (check (highlighted) => ["12" "34"])))))

    (test-case "a digit highlight grows over text typed inside its run while the job ran"
      (call-with-fresh-kernel job-plugins
       (lambda ()
         (start-editor-loop!)
         (let (gate (make-completion))
           (type! "a" "1" "2" "3" "b")
           (start-gated-digits! gate)
           (type! "C-a" "C-f" "C-f" "x")
           (check (on-baton (lambda () (text-string (current-text)))) => "a1x23b")
           (completion-post! gate #t)
           (check (wait-until (lambda () (pair? (highlighted)))) => #t)
           (check (highlighted) => ["1x23"])))))))
