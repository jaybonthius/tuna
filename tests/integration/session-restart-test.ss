;;; Integration: a restart through the session and autosave plugins while
;;; the whole editor runs. Typing, renaming, views split and tabbed, the
;;; frame moved and a frame mark set, then a simulated restart, with the
;;; real keys, editing, layout and rendering plugins. tuna/plugins/session-test.ss tests the session
;;; and autosave plugins alone.
(import (only-in :tuna/boot session-owner restart-plugin!)
        :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/session/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/session/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/autosave/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/completion/plugin
        :tuna/plugins/extended-command/plugin
        :tuna/plugins/renderer/contract
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        "../support/swap-commands")
(export session-restart-test)

(defplugin (swap-configuration ctx)
  "Selects the default providers for swap commands in this test configuration."
  (context-set-swap-providers! ctx html-renderer layout buffers))


(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-session-restart-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

(def editor-plugins
  [session-owner commands keys echo-area rope-text-store settings
   session buffers autosave layout view-commands
   html-renderer basic-editing minibuffer completion-engine extended-command
   swap-configuration swap-commands])

;; One run of Tuna on DIRECTORY, booted as main does: activate, restore,
;; start the loop.
(def (run-tuna directory thunk)
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory directory))
        (for-each activate-plugin! editor-plugins))
      (restore-session)
      (start-editor-loop!)
      (thunk))))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; The views outside the bar: those whose buffers are not internal.
(def (own-views)
  (filter (lambda (v) (not (internal-buffer? (view-showing v)))) (view-list)))

(def (views-state)
  (on-baton
   (lambda ()
     (map (lambda (v) [(buffer-name (view-showing v)) (view-point v)])
          (own-views)))))

;; The index of the selected view among them.
(def (selected-index)
  (on-baton
   (lambda ()
     (let lp ((views (own-views)) (i 0))
       (if (eq? (car views) (selected-view)) i (lp (cdr views) (+ i 1)))))))

(def (screen)
  (on-baton (lambda () (html->string (Renderer-render-screen (Renderer (service-provider renderer-service)) #f)))))

(def (count-of needle haystack)
  (let lp ((start 0) (n 0))
    (let (found (string-contains haystack needle start))
      (if found (lp (+ found 1) (+ n 1)) n))))

(def (buffer-text name)
  (on-baton
   (lambda ()
     (let (b (get-buffer name))
       (and b (text-string (text-node-content (first-text-node (buffer-root b)))))))))

(def (file-text path)
  (call-with-input-file [path: path char-encoding: 'UTF-8]
    (lambda (port)
      (let (content (read-line port #f))
        (if (eof-object? content) "" content)))))

(def (read-session-datum directory)
  (call-with-input-file [path: (path-expand "session.ss" directory) char-encoding: 'UTF-8] read))

(def session-restart-test
  (test-suite "integration: a session restart"
    (test-case "a swap chosen through M-x retires its own command quietly"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
          (lambda ()
            (let ((outcomes []) (before (on-baton (lambda () (service-provider buffers-service)))))
              (defplugin (completion-observer ctx) "Observes task outcomes across swaps."
                (context-add-hook! ctx task-finished-hook 'outcomes
                  (lambda (id name how) (set! outcomes (cons [name how] outcomes)))))
              (on-baton (lambda () (activate-plugin! completion-observer)))
              (type! "h" "i")
              (type! "M-x" "s" "w" "a" "p" "-" "b" "u" "f" "f" "e" "r" "s" "RET")
              (check (buffer-text "*scratch*") => "hi")
              (check (on-baton (lambda () (eq? before (service-provider buffers-service)))) => #f)
              (check (on-baton (lambda () (assoc 'execute-extended-command outcomes)))
                     => '(execute-extended-command returned))
              (check (and (string-contains (screen) "Quit") #t) => #f)
              (type! "M-x" "s" "w" "a" "p" "-" "b" "u" "f" "f" "e" "r" "s" "RET")
              (check (buffer-text "*scratch*") => "hi")
              (check (and (string-contains (screen) "Quit") #t) => #f)))))))
    (test-case "buffers, their text and names, and points come back after a restart"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (type! "h" "i" "1" "RET" "t" "h" "é" "r" "e" "😀" "C-p" "C-a" "C-f")
             (on-baton (lambda ()
                         (rename-buffer! (current-buffer) "notes")
                         (let (b (new-buffer "other" (new-text-node (new-text "another text"))))
                           (add-buffer! b)
                           (set-buffer-point! b 4))))
             (on-baton save-session)))
         (check (list-sort string<? (directory-files (path-expand "autosave" directory)))
                => ["notes" "other"])
         (check (file-text (path-expand "autosave/notes" directory)) => "hi1\nthére😀")
         (run-tuna directory
           (lambda ()
             (check (on-baton (lambda () (map buffer-name (filter (lambda (b) (not (internal-buffer? b))) (buffer-list)))))
                    => ["*scratch*" "notes" "other"])
             (check (buffer-text "notes") => "hi1\nthére😀")
             (check (buffer-text "other") => "another text")
             (check (on-baton (lambda () (buffer-point (get-buffer "other")))) => 4)
             (check (views-state) => [["notes" 2]])
             ;; Typing goes on where it left off; the restored text is not undoable.
             (type! "X")
             (check (buffer-text "notes") => "hXi1\nthére😀")
             (type! "C-/" "C-/")
             (check (buffer-text "notes") => "hi1\nthére😀"))))))

    (test-case "the layout, the frame and frame marks come back after a restart"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             ;; Two views side by side; the left one becomes the first of
             ;; two tabs; a frame mark on the whole layout; the frame on
             ;; the new tab's view.
             (type! "a" "b" "c" "C-x" "3" "C-b" "C-b" "C-x" "t" "2")
             (type! "C-x" "r" "w" "m" "RET" "C-x" "1")
             (check (views-state) => [["*scratch*" 2] ["*scratch*" 2] ["*scratch*" 4]])
             (check (selected-index) => 1)
             (on-baton save-session)))
         (check (match (assq 'layout-tree (cddr (read-session-datum directory)))
                  ;; The bar at the bottom: content-sized, pinned and locked.
                 (['layout-tree 2 [['tree ['container _ 'fit 'vertical _
                                      [[1 [] ['container _ 'fit 'horizontal _
                                              [[1 [] ['container _ 'tabbed 'horizontal _ _]]
                                               [1 [] ['view [_ "*scratch*" _ 4 _] #f]]]]]
                                       ['content ['pinned 'locked] _]]]]
                               ['frame (? fixnum?) #f (? fixnum?)]
                               ['marks ["m" #f #f]]]]
                   #t)
                  (else #f))
                => #t)
         (run-tuna directory
           (lambda ()
             (check (views-state) => [["*scratch*" 2] ["*scratch*" 2] ["*scratch*" 4]])
             (check (selected-index) => 1)
             ;; The frame is still on the selected view: the screen shows
             ;; one view, and the bar's two, which are pinned.
             (check (on-baton (lambda () (frame-target-part (current-frame-target))))
                    => (on-baton (lambda () (view-id (selected-view)))))
             (check (count-of "<section class=\"view\"" (screen)) => 3)
             (type! "C-x" "r" "j" "m" "RET")
             (check (on-baton (lambda () (frame-target-part (current-frame-target)))) => #f)
             (check (count-of "<section class=\"view\"" (screen)) => 4)
             (check (count-of "class=\"tab\"" (screen)) => 2)
             (check (buffer-text "*scratch*") => "abc"))))))

    (test-case "each view comes back where it was scrolled, as a placement with its offset"
      (call-with-state-directory
       (lambda (directory)
         (let ((line-item (lambda (v line) (node-item-at (view-node v) (- line 1))))
               (placed (lambda (v)
                         (let (p (view-placement v))
                           [(item-line (placement-target p)) (placement-align p) (placement-offset p)]))))
           (run-tuna directory
             (lambda ()
               (on-baton (lambda ()
                           (insert (string-join (map number->string (iota 1000 1)) "\n"))
                           (goto-char (text-line-start (current-text) 310))
                           ;; Measured: line 300 at the top, 5.5 px of it above the edge.
                           (set-view-scroll! (selected-view) #f (line-item (selected-view) 300) 5.5)))
               (type! "C-x" "3")
               ;; The new view is placed, not yet measured: line 700 at its centre.
               (on-baton (lambda ()
                           (let (v (cadr (own-views)))
                             (place-view! v (line-item v 700) 'center))))
               (on-baton save-session)))
           (run-tuna directory
             (lambda ()
               (match (own-views)
                 ([left right]
                  (check (on-baton (lambda () (placed left))) => [300 'top 5.5])
                  (check (on-baton (lambda () (placed right))) => [700 'center 0.])
                  (let (start (on-baton (lambda () (text-line-start (current-text) 310))))
                    (check (views-state) => [["*scratch*" start] ["*scratch*" start]]))
                  (check (and (string-contains (screen) "data-align=\"top\" data-offset=\"5.5\"") #t) => #t))
                 (else (check (length (own-views)) => 2)))))))))

    (test-case "swapping the buffers provider keeps live text and every view's point"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (type! "h" "e" "l" "l" "o" "RET" "w" "o" "r" "l" "d" "C-x" "3")
             (type! "C-x" "o" "C-a" "C-x" "o" "C-p")
             (on-baton save-session)
             ;; Typed after the save: the autosave file is older than the text.
             (type! "!")
             (check (views-state) => [["*scratch*" 7] ["*scratch*" 8]])
             (type! "C-c" "B")
             (check (buffer-text "*scratch*") => "hello!\nworld")
             (check (views-state) => [["*scratch*" 7] ["*scratch*" 8]])
             (type! "C-c" "B")
             (check (buffer-text "*scratch*") => "hello!\nworld")
             (check (views-state) => [["*scratch*" 7] ["*scratch*" 8]]))))))

    (test-case "a restored layout skips views of buffers that are gone"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (on-baton (lambda ()
                         (let (b (new-buffer "gone" (new-node 'column)))
                           (add-buffer! b)
                           (display-buffer b side: 'left size: 1/5))))
             (check (map car (views-state)) => ["gone" "*scratch*"])
             (on-baton save-session)))
         (run-tuna directory
           (lambda ()
             ;; Autosave keeps only buffers of one text node, so "gone" is gone.
             (check (views-state) => [["*scratch*" 1]]))))))))
