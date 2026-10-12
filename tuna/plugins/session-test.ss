;;; The session and autosave plugins: saving, restoring across a simulated
;;; restart, corrupt files, unknown slots, and atomic writes. Every test
;;; uses its own temporary state directory.
(import :std/test
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/session
        :tuna/services/windows
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/session
        :tuna/plugins/buffers
        :tuna/plugins/autosave
        :tuna/plugins/single-window
        :tuna/plugins/window-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo)
(export session-test)

(include "test-keys.ss")

(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-session-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

(def session-plugins
  [keys-plugin echo-area-plugin help-panel-plugin rope-text-store-plugin settings-plugin
   session-plugin buffers-plugin autosave-plugin single-window-plugin window-commands-plugin
   html-renderer-plugin basic-editing-plugin minibuffer-plugin demo-plugin])

;; One run of Tuna on DIRECTORY, booted as main does: activate, restore,
;; start the loop.
(def (run-tuna directory thunk)
  (parameterize ((current-kernel (new-kernel)))
    (try
     (parameterize ((session-state-directory directory))
       (for-each activate-plugin! session-plugins))
     (restore-session)
     (start-editor-loop!)
     (thunk)
     (finally
      (stop-editor-loop!)
      (deactivate-all-plugins!)))))

(def (on-baton thunk) (call-on-editor-loop thunk))

(def (windows-state)
  (on-baton
   (lambda ()
     (map (lambda (w)
            (let (v (window-view w))
              [(buffer-name (view-showing v)) (view-point v)]))
          (window-list)))))

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

(def (session-file directory) (path-expand "session.ss" directory))

(def (read-session-datum directory)
  (call-with-input-file [path: (session-file directory) char-encoding: 'UTF-8] read))

(def (write-session! directory text)
  (call-with-output-file [path: (session-file directory) char-encoding: 'UTF-8]
    (lambda (port) (display text port))))

(def (corrupt-files directory)
  (filter (cut string-prefix? "session.ss.corrupt-" <>) (directory-files directory)))

(defplugin (unplain-slot ctx)
  "Registers a session slot whose data is not plain."
  (context-add-session-slot! ctx 'unplain version: 1
                             save: (lambda () [(lambda () 'code)])
                             restore: void))

;; Restored slot data, newest first, as (slot version data).
(def restored [])

(def (restore-into name version)
  (lambda (data) (set! restored (cons [name version data] restored))))

(defplugin (slots-early ctx)
  "Registers the session slot alpha."
  requires: [session-service]
  (context-add-session-slot! ctx 'alpha version: 1 save: (lambda () "early")
                             restore: (restore-into 'alpha 1)))

(defplugin (slots-late ctx)
  "Registers the session slots beta, and alpha at a higher priority."
  requires: [session-service]
  (context-add-session-slot! ctx 'beta version: 2 save: (lambda () "late beta")
                             restore: (restore-into 'beta 2))
  (context-add-session-slot! ctx 'alpha version: 3 save: (lambda () "late")
                             restore: (restore-into 'alpha 3)
                             priority: 10))

;; A fresh kernel with only the session plugin on DIRECTORY, without the
;; editor loop.
(def (with-session-only directory thunk)
  (parameterize ((current-kernel (new-kernel)))
    (try
     (parameterize ((session-state-directory directory))
       (activate-plugin! session-plugin))
     (thunk)
     (finally
      (deactivate-all-plugins!)))))

(def (effective-slots)
  (map (lambda (slot) [(session-slot-name slot) (session-slot-version slot)
                       ((session-slot-save slot))])
       (session-slots)))

(def session-test
  (test-suite "tuna/plugins/session"
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
             (check (on-baton (lambda () (map buffer-name (buffer-list))))
                    => ["*scratch*" "*welcome*" "notes" "other"])
             (check (buffer-text "notes") => "hi1\nthére😀")
             (check (buffer-text "other") => "another text")
             (check (on-baton (lambda () (buffer-point (get-buffer "other")))) => 4)
             (check (windows-state) => [["notes" 2]])
             ;; Typing goes on where it left off; the restored text is not undoable.
             (type! "X")
             (check (buffer-text "notes") => "hXi1\nthére😀")
             (type! "C-/" "C-/")
             (check (buffer-text "notes") => "hi1\nthére😀"))))))

    (test-case "a session saved with two windows restores the selected one under one window"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (type! "a" "b" "c" "C-c" "w" "C-b" "C-b" "C-x" "o")
             (check (windows-state) => [["*scratch*" 2] ["*scratch*" 4]])
             (on-baton save-session)))
         (check (assq 'windows (cddr (read-session-datum directory)))
                => ['windows 1 [['selected 1] ['windows ["*scratch*" 2] ["*scratch*" 4]]]])
         (run-tuna directory
           (lambda ()
             (check (windows-state) => [["*scratch*" 4]])
             (check (buffer-text "*scratch*") => "abc"))))))

    (test-case "the session is saved while idle, and only when it changed"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (type! "z")
             (let ((autosave (path-expand "autosave/%2Ascratch%2A" directory)))
               (let lp ((tries 50))
                 (unless (or (zero? tries)
                             (and (file-exists? autosave) (equal? (file-text autosave) "z")))
                   (thread-sleep! 0.1)
                   (lp (- tries 1))))
               (check (file-text autosave) => "z"))
             ;; The session file is written right after the autosave files.
             (thread-sleep! 0.2)
             (check (assq 'buffers (cddr (read-session-datum directory)))
                    => ['buffers 1 [["*scratch*" 2 "%2Ascratch%2A"]]])
             (let (stamp (file-info-last-modification-time (file-info (session-file directory))))
               (thread-sleep! 2.5)
               (check (time->seconds (file-info-last-modification-time
                                      (file-info (session-file directory))))
                      => (time->seconds stamp))))))))

    (test-case "session slots follow their plugins; the oldest name comes first"
      (call-with-state-directory
       (lambda (directory)
         (with-session-only directory
           (lambda ()
             (activate-plugin! slots-early)
             (activate-plugin! slots-late)
             (check (effective-slots) => [['alpha 3 "late"] ['beta 2 "late beta"]])
             (deactivate-plugin! slots-late)
             (check (effective-slots) => [['alpha 1 "early"]])
             (deactivate-plugin! slots-early)
             (check (effective-slots) => []))))))

    (test-case "deactivating a slot's plugin makes a same-named lower-priority slot effective"
      (call-with-state-directory
       (lambda (directory)
         (with-session-only directory
           (lambda ()
             (activate-plugin! slots-early)
             (activate-plugin! slots-late)
             (save-session)
             (check (cddr (read-session-datum directory))
                    => [['alpha 3 "late"] ['beta 2 "late beta"]])
             (deactivate-plugin! slots-late)
             (save-session)
             (check (cddr (read-session-datum directory))
                    => [['alpha 1 "early"] ['beta 2 "late beta"]])))
         (set! restored [])
         (with-session-only directory
           (lambda ()
             (activate-plugin! slots-early)
             (activate-plugin! slots-late)
             ;; alpha was saved by the lower-priority slot, version 1, so the
             ;; effective alpha (version 3) skips it; beta restores.
             (restore-session)
             (check (reverse restored) => [['beta 2 "late beta"]])
             (deactivate-plugin! slots-late)
             (restore-session)
             (check (reverse restored) => [['beta 2 "late beta"] ['alpha 1 "early"]]))))))

    (test-case "a corrupt session file is moved aside and reported, never evaluated"
      (call-with-state-directory
       (lambda (directory)
         (for-each
           (lambda (content)
             (write-session! directory content)
             (run-tuna directory
               (lambda ()
                 (check (file-exists? (session-file directory)) => #f)
                 (check (string-prefix? "The session file could not be read; moved it to"
                                        (on-baton current-message))
                        => #t)
                 (check (on-baton (lambda () (map buffer-name (buffer-list))))
                        => ["*scratch*" "*welcome*"])))
             (let (aside (path-expand (car (corrupt-files directory)) directory))
               (check (file-text aside) => content)
               (delete-file aside)))
           ["(tuna-session 1 (buffers 1 ((\"x\" 1 \"x\"))"           ; truncated
            "(tuna-session 1 (buffers 1 #.(exit 3)))"              ; read-time evaluation
            "(tuna-session 1 (windows 1 #!eof))"                   ; not plain data
            "(tuna-session 1) (more)"                              ; two data
            "(tuna-session 99 (buffers 1 ()))"                     ; unknown format
            ""])
         ;; Saving afterwards writes a fresh file.
         (write-session! directory "garbage)")
         (run-tuna directory (lambda () (on-baton save-session)))
         (check (file-exists? (session-file directory)) => #t)
         (check (length (corrupt-files directory)) => 1))))

    (test-case "slots no plugin registers are kept; failing slots keep their old data"
      (call-with-state-directory
       (lambda (directory)
         (write-session! directory
                         "(tuna-session 1 (mystery 3 (a \"b\" #(1 2))) (unplain 1 \"old\"))")
         (run-tuna directory
           (lambda ()
             (on-baton (lambda () (activate-plugin! unplain-slot)))
             (on-baton save-session)
             (check (on-baton current-message)
                    => "Session slot unplain failed to save: Session slot data is not plain data unplain")))
         (let (entries (cddr (read-session-datum directory)))
           (check (assq 'mystery entries) => ['mystery 3 ['a "b" #(1 2)]])
           (check (assq 'unplain entries) => ['unplain 1 "old"])
           (check (and (assq 'buffers entries) (assq 'windows entries) #t) => #t)))))

    (test-case "a session cannot point autosave outside its directory"
      (call-with-state-directory
       (lambda (directory)
         (write-session! directory "(tuna-session 1 (buffers 1 ((\"evil\" 1 \"../evil\"))))")
         (call-with-output-file (path-expand "evil" directory) (lambda (port) (display "secret" port)))
         (run-tuna directory
           (lambda ()
             (check (on-baton (lambda () (get-buffer "evil"))) => #f))))))

    (test-case "files are replaced atomically: a failed write leaves the old file"
      (call-with-state-directory
       (lambda (directory)
         (let (path (path-expand "data.ss" directory))
           (write-file-atomically! path (lambda (port) (display "old" port)))
           (check (file-text path) => "old")
           (check (with-catch (lambda (e) 'failed)
                              (lambda ()
                                (write-file-atomically! path
                                                        (lambda (port)
                                                          (display "partial" port)
                                                          (error "disk full")))))
                  => 'failed)
           (check (file-text path) => "old")
           (check (directory-files directory) => ["data.ss"])
           (write-file-atomically! path (lambda (port) (display "new" port)))
           (check (file-text path) => "new")
           (check (directory-files directory) => ["data.ss"])))))

    (test-case "plain data excludes code, keywords, special objects, and cycles"
      (check (plain-data? ['a "b" #\c 1 -2/3 1.5 #t #f #(1 [2]) [] '(x . y)]) => #t)
      (check (plain-data? [car]) => #f)
      (check (plain-data? [(string->keyword "a")]) => #f)
      (check (plain-data? (void)) => #f)
      (check (plain-data? +inf.0) => #f)
      (check (plain-data? (let (cycle [1 2]) (set-cdr! (cdr cycle) cycle) cycle)) => #f))

    (test-case "autosave file names keep only safe characters"
      (check (autosave-file-name "*scratch*") => "%2Ascratch%2A")
      (check (autosave-file-name "a/b é-_") => "a%2Fb%20%C3%A9-_")
      (check (autosave-file-name "..") => "%2E%2E"))))
