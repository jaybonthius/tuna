;;; The demo's minibuffer rename, slow digit highlighter, and
;;; describe-services, driven through the real editor loop.
(import :std/sync/completion
        :std/test
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/help
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo)
(export demo-test)

(include "test-keys.ss")

(def (with-demo thunk)
  (call-with-editor [keys-plugin echo-area-plugin help-panel-plugin rope-text-store-plugin
                     settings-plugin buffers-plugin html-renderer-plugin basic-editing-plugin
                     minibuffer-plugin demo-plugin]
                    thunk))

(def (with-editing thunk)
  (call-with-editor [keys-plugin echo-area-plugin rope-text-store-plugin settings-plugin
                     buffers-plugin basic-editing-plugin]
                    thunk))

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
      (with-demo
       (lambda ()
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
      (with-demo
       (lambda ()
         (type! "C-c" "r" "x")
         (check (contains? (screen) "New name: ") => #t)
         (type! "C-g")
         (let (html (screen))
           (check (contains? html "class=\"minibuffer\"") => #f)
           (check (contains? html "Tuna · *scratch*") => #t)
           (check (contains? html ">Quit<") => #t)))))

    (test-case "C-h s shows buffers adapting to the text store"
      (with-demo
       (lambda ()
         (type! "C-h" "s")
         (check (on-baton (lambda () (help-output-lines (current-help))))
                ? (cut member
                       "text-store (live)  provider: rope-text-store-plugin  dependents: buffers-plugin (adapts)"
                       <>)))))

    (test-case "the slow highlighter colors digits shortly after typing"
      (with-demo
       (lambda ()
         (type! "a" "1" "2" "b" "3")
         (check (wait-until (lambda () (equal? (highlighted) ["12" "3"]))) => #t)
         (check (contains? (screen) "a<span class=\"face-digit\">12</span>b") => #t)
         ;; Typing continues: the colors follow.
         (type! "C-a" "x" "4")
         (check (wait-until (lambda () (equal? (highlighted) ["4" "12" "3"]))) => #t))))

    (test-case "rebased digit highlights land on the right characters after edits made while the job ran"
      (with-editing
       (lambda ()
         (let (gate (make-completion))
           (type! "a" "1" "2" "b" "3" "4")
           (on-baton
            (lambda ()
              (let (t (current-text))
                (start-job 'gated-digits
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
