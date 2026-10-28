;;; Integration: the profiler follows a key typed in a browser tab through
;;; the real plugins, over real loopback HTTP, and writes its span tree to
;;; the profile folder once both tabs' pages painted the screen; turning
;;; it off leaves no listener on any hook it used.
(import :std/error
        (only-in :gerbil/runtime/thread spawn-thread)
        :std/sync/completion
        (only-in :tuna/prelude advise!)
        :std/interface
        :std/io
        :std/test
        (only-in :std/encoding/json string->json current-json-read-options JSONReadOptions)
        :tuna/kernel
        :tuna/configuration
        :tuna/lib/plugin-options
        :tuna/lib/jobs
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/web/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/web/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/scrolling/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/editing/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/profiler/plugin
        "../../plugins/session/tests/support/session"
        "../../plugins/web/tests/support/web-client"
        (rename-in "../../tuna/tests/support/kernel" (activate-plugin! activate-kernel-plugin!)))
(export profiler-test)

(def profiled-plugins
  [commands keys web-transport echo-area rope-text-store settings no-session buffers
   layout minibuffer scrolling html-renderer editing profiler profiler-commands])

(def (call-with-profile-folder proc)
  (let (folder (path-expand (string-append "tuna-profiler-test-" (number->string (random-integer 1000000000)))
                            (getenv "TMPDIR" "/tmp")))
    (try
     (proc folder)
     (finally
      (when (file-exists? folder) (delete-file-or-directory folder #t))))))

(def (with-profiled-tuna folder options thunk)
  (set-plugin-options! profiler (cons (cons 'folder folder) options))
  (try
   (with-web-tuna profiled-plugins thunk)
   (finally (set-plugin-options! profiler []))))

;; The /applied path of the last screen in TEXT, as its page posts it.
(def (applied-path text)
  (let lp ((at 0) (last #f))
    (let (found (string-search-from "/applied?stream=" text at))
      (if found
        (lp (+ found 1) found)
        (let (end (string-index text #\' last))
          (string-join (string-split-on (substring text last end) "&amp;") "&"))))))

(def (string-search-from needle text start)
  (let (found (string-search needle (substring text start (string-length text))))
    (and found (+ found start))))

(def (string-split-on text separator)
  (let (at (string-search separator text))
    (if at
      (cons (substring text 0 at)
            (string-split-on (substring text (+ at (string-length separator)) (string-length text)) separator))
      [text])))

;; The query number NAME of PATH.
(def (query-number path name)
  (let* ((at (+ (string-search (string-append name "=") path) (string-length name) 1))
         (end (or (string-index path #\& at) (string-length path))))
    (substring path at end)))

;; The last data-revision in TEXT.
(def (last-revision text)
  (let lp ((at 0) (last #f))
    (let (found (string-search-from "data-revision=\"" text at))
      (if found
        (lp (+ found 1) found)
        (let (from (+ last 15)) (substring text from (string-index text #\" from)))))))

(def (has-screen? text) (and (string-search "data-revision=\"" text) #t))

(def (wait-for ready? tries: (tries 500))
  (let lp ((n tries))
    (cond
     ((ready?) #t)
     ((zero? n) #f)
     (else (thread-sleep! 0.01) (lp (- n 1))))))

;; Every JSON line written to spans files in FOLDER, oldest file first.
(def (span-lines folder)
  (if (file-exists? folder)
    (apply append
           (map (lambda (name)
                  (call-with-input-file (path-expand name folder)
                    (lambda (port)
                      (let lp ((out []))
                        (let (line (read-line port))
                          (if (eof-object? line)
                            (reverse out)
                            (lp (cons (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                                        (string->json line))
                                      out))))))))
                (filter (cut string-prefix? "spans-" <>) (list-sort string<? (directory-files folder)))))
    []))

(def (trees folder) (filter (cut hash-key? <> "span") (span-lines folder)))

(def (child json name)
  (find (lambda (c) (equal? (hash-ref c "name") name)) (hash-ref json "children")))

(def (child-names json)
  (map (lambda (c) (hash-ref c "name")) (hash-ref json "children")))

(def (detail json name)
  (hash-get (hash-ref json "details") name))

;; Confirm the screen in TEXT for TAB, with MEASURED, raw JSON fields of
;; what the page measured, then report its paint.
(def (apply-and-paint! text tab measured paint)
  (let (path (applied-path text))
    (post-applied path tab: tab
                  applied: (string-append "{\"revision\":" (last-revision text) "," measured "}"))
    (post-applied path tab: tab
                  applied: (string-append "{\"painted\":[[" (query-number path "stream") ","
                                          (query-number path "count") "," paint "]]}"))))

;; A configuration service that turns plugins on as start-up does, for
;; profiler-mode.
(defclass stub-configuration () final: #t)
(implement Configuration stub-configuration
  (activate! (lambda (self target order) (activate-kernel-plugin! target)))
  (reload! (lambda (self) ""))
  (set-restart-wrapper! (lambda (self ctx wrapper) (void)))
  (restart (lambda (self owners apply rollback) (apply)))
  (swap! (lambda (self old new) (void)))
  (last-report (lambda (self) #f))
  (evaluate (lambda (self form) (void))))
(defplugin (stub-configuration-plugin ctx)
  "Turns plugins on for profiler-mode."
  provides: [configuration-service]
  (context-provide! ctx configuration-service (Configuration (stub-configuration))))

;; Every hook the profiler listens to.
(def followed-hooks
  [input-arrived-hook input-resolved-hook task-started-hook task-finished-hook
   pre-command-hook post-command-hook job-started-hook job-finished-hook
   redraw-started-hook redraw-finished-hook screen-ready-hook screen-sent-hook screen-applied-hook])

(def (profiler-callbacks)
  (filter-map (lambda (h)
                (let (names (filter (lambda (name) (memq name '(profiler profiler-first profiler-last)))
                                    (hook-callback-names h)))
                  (and (pair? names) names)))
              followed-hooks))

;; Whether NAME is a written samples file (not one still being written).
(def (samples-file? name)
  (and (string-prefix? "samples-" name) (string-suffix? ".folded" name)))

;; Holds the profiler's writing of samples until the test opens GATE, so a
;; test can see profiler-stop return while the write still waits.
(def gate #f)
(defplugin (gated-samples ctx)
  "Makes the profiler's sample writing wait for the test's gate."
  (advise! ctx (function :tuna/plugins/profiler/plugin write-samples) 'gate
           around: (lambda (original samples folder)
                     (completion-wait! gate)
                     (original samples folder))))

(def profiler-test
  (test-suite "integration: the profiler"
    (test-case "a key typed in one of two tabs is written as one tree, from the key to both tabs' paints"
      (call-with-profile-folder
       (lambda (folder)
         (with-profiled-tuna folder []
           (lambda ()
             (let* ((a (current-tab))
                    (a-stream (open-screen-stream tab: a))
                    (a-first (read-until a-stream has-screen?))
                    (b (new-tab!))
                    (b-stream (open-screen-stream tab: b))
                    (b-first (read-until b-stream has-screen?)))
               (post-applied (applied-path a-first) tab: a)
               (post-applied (applied-path b-first) tab: b)
               (post-key "q" tab: a)
               (let ((a-text (read-until a-stream (cut string-search "q<span" <>)))
                     (b-text (read-until b-stream (cut string-search "q<span" <>))))
                 (check (and (string-search "data-through=\"1\"" a-text) #t) => #t)
                 (apply-and-paint! a-text a "\"through\":1,\"morph\":2,\"settle\":0.5,\"keys\":[[1,1.5,30]]" "8")
                 (apply-and-paint! b-text b "\"through\":0,\"morph\":3,\"settle\":0.25" "9"))
               (check (wait-for (lambda () (pair? (trees folder)))) => #t)
               (let* ((tree (car (trees folder)))
                      (root (hash-ref tree "span"))
                      (tabs (filter (cut string-prefix? "tab " <>) (child-names root))))
                 (check (hash-ref tree "complete") => #t)
                 (check (hash-ref tree "sequence") => 1)
                 (check (detail root "key") => "q")
                 (check (detail root "command") => "self-insert-command")
                 (check (detail root "key-to-paint") => 42.)
                 (for-each (lambda (name) (check (and (child root name) #t) => #t))
                           ["queue" "task self-insert-command" "browser: key to send" "network"])
                 (check (length tabs) => 2)
                 (let (task (child root "task self-insert-command"))
                   (check (child-names task) => ["pre-command-hook" "command self-insert-command" "post-command-hook"])
                   (check (> (hash-ref task "allocated") 0) => #t))
                 (for-each
                  (lambda (name)
                    (let (branch (child root name))
                      (check (child-names branch) => ["redraw" "waiting for the tab" "write" "network and browser"])
                      (check (> (detail (child branch "redraw") "drawn") 0) => #t)
                      (check (> (detail (child branch "redraw") "bytes") 0) => #t)
                      (check (child-names (child branch "network and browser"))
                             => ["browser: morph" "browser: settle" "browser: paint"])))
                  tabs))
               ;; Written, then forgotten: the header line, then one line per item.
               (check (hash-key? (car (span-lines folder)) "tuna") => #t)
               (Socket-close a-stream)
               (Socket-close b-stream)))))))

    (test-case "items shorter than the minimum are not written; a full file is followed by a new one"
      (call-with-profile-folder
       (lambda (folder)
         (with-profiled-tuna folder [(cons 'minimum 3600000)]
           (lambda ()
             (let* ((stream (open-screen-stream))
                    (first (read-until stream has-screen?)))
               (post-applied (applied-path first))
               (post-key "x")
               (let (text (read-until stream (cut string-search "x<span" <>)))
                 (apply-and-paint! text (current-tab) "\"through\":1" "1"))
               (thread-sleep! 0.5)
               (check (trees folder) => [])
               (Socket-close stream))))))
      (call-with-profile-folder
       (lambda (folder)
         (with-profiled-tuna folder [(cons 'file-size 1024)]
           (lambda ()
             (let* ((stream (open-screen-stream))
                    (first (read-until stream has-screen?)))
               (post-applied (applied-path first))
               (let lp ((keys ["x" "y"]) (text first))
                 (unless (null? keys)
                   (post-key (car keys))
                   (let (next (read-until stream (cut string-search (string-append (car keys) "<span") <>)))
                     (apply-and-paint! next (current-tab) "\"through\":1" "1")
                     (wait-for (lambda () (= (length (trees folder)) (if (equal? (car keys) "x") 1 2))))
                     (lp (cdr keys) next))))
               (check (length (trees folder)) => 2)
               (check (length (filter (cut string-prefix? "spans-" <>) (directory-files folder))) => 2)
               (Socket-close stream)))))))

    (test-case "profiler-mode turns the profiler off, leaving no listener on any hook it used, and on again"
      (call-with-profile-folder
       (lambda (folder)
         (set-plugin-options! profiler [(cons 'folder folder)])
         (try
          (call-with-fresh-kernel (cons stub-configuration-plugin profiled-plugins)
            (lambda ()
              (start-editor-loop!)
              (check (length (profiler-callbacks)) => (length followed-hooks))
              (call-on-editor-loop (lambda () (call-command 'profiler-mode)))
              (check (plugin-active? profiler) => #f)
              (check (profiler-callbacks) => [])
              (call-on-editor-loop (lambda () (call-command 'profiler-mode)))
              (check (plugin-active? profiler) => #t)
              (check (length (profiler-callbacks)) => (length followed-hooks))))
          (finally (set-plugin-options! profiler []))))))

    (test-case "profiler-stop returns at once; the samples are written off the editor thread"
      (call-with-profile-folder
       (lambda (folder)
         (set! gate (make-completion))
         (set-plugin-options! profiler [(cons 'folder folder)])
         (try
          (call-with-fresh-kernel (append profiled-plugins [gated-samples])
            (lambda ()
              (start-editor-loop!)
              (call-on-editor-loop (lambda () (call-command 'profiler-start)))
              (list-sort < (iota 3000))
              ;; The command finishes while the write waits at the gate.
              (let (stopping (spawn-thread (lambda () (call-on-editor-loop (lambda () (call-command 'profiler-stop))))))
                (check (thread-join! stopping 5 'still-waiting) ? (lambda (v) (not (eq? v 'still-waiting)))))
              (check (filter samples-file?
                             (if (file-exists? folder) (directory-files folder) []))
                     => [])
              (completion-post! gate #t)
              (check (wait-for (lambda () (and (file-exists? folder)
                                               (pair? (filter samples-file?
                                                              (directory-files folder))))))
                     => #t)))
          (finally (set-plugin-options! profiler []))))))

    (test-case "profiler-start and profiler-stop write the samples taken, a stack per line"
      (call-with-profile-folder
       (lambda (folder)
         (set-plugin-options! profiler [(cons 'folder folder)])
         (try
          (call-with-fresh-kernel profiled-plugins
            (lambda ()
              (start-editor-loop!)
              (call-on-editor-loop (lambda () (call-command 'profiler-start)))
              (let (deadline (+ (time->seconds (current-time)) .3))
                (let lp () (when (< (time->seconds (current-time)) deadline) (list-sort < (iota 300)) (lp))))
              (call-on-editor-loop (lambda () (call-command 'profiler-stop)))
              (wait-for (lambda () (and (file-exists? folder)
                                        (pair? (filter samples-file? (directory-files folder))))))
              (let (files (filter samples-file? (directory-files folder)))
                (check (length files) => 1)
                (let (lines (call-with-input-file (path-expand (car files) folder)
                              (lambda (port) (read-all port read-line))))
                  (check (pair? lines) => #t)
                  (check (andmap (lambda (line) (= (length (string-split line #\space)) 2)) lines) => #t)))))
          (finally (set-plugin-options! profiler []))))))))
