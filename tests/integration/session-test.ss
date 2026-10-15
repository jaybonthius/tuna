;;; The session plugin and its slot clients autosave and the layout:
;;; saving, restoring across a simulated restart, corrupt files, unknown
;;; slots, and atomic writes. Every test uses its own temporary state
;;; directory.
(import (only-in :tuna/boot session-owner restart-plugin!)
        :std/test
        :std/error
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/session/contract
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/session/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/autosave/plugin
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/layout/plugin
        "../../tuna/tests/support/kernel"
        (only-in "../../tuna/tests/support/string-input" test-messages current-message))
(export session-test)

(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-session-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

;; The session and autosave plugins, the plugins that fill the slots they
;; and the layout require (keys for input), and a stand-in for messages.
(def session-plugins
  [commands keys test-messages rope-text-store settings
   session buffers autosave layout])

;; One run of Tuna on DIRECTORY, booted as main does: activate, restore,
;; start the loop.
(def (run-tuna directory thunk)
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory directory))
        (for-each activate-plugin! session-plugins))
      (restore-session)
      (start-editor-loop!)
      (thunk))))

(def (on-baton thunk) (call-on-editor-loop thunk))

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
  requires: [session-service]
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
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory directory))
        (activate-plugin! session-owner)
        (activate-plugin! session))
      (thunk))))

(def restart-state-service (new-service 'restart-state symbol? tier: 'live doc: "A provider with saved test state."))
(def owned-value 0)
(def dependent-value 0)
(def fail-restoration? #f)

(defplugin (restart-owner ctx)
  "Owns state whose cleanup runs before its session slot is removed."
  requires: [session-service]
  provides: [restart-state-service]
  (set! owned-value 10)
  (context-provide! ctx restart-state-service 'old)
  (context-add-session-slot! ctx 'restart-state version: 1
                             save: (lambda () owned-value)
                             restore: (lambda (data) (set! owned-value data)))
  (context-defer! ctx (lambda () (set! owned-value -1))))

(defplugin (restart-replacement ctx)
  "Restores the neutral saved state into an alternative provider."
  requires: [session-service]
  provides: [restart-state-service]
  (set! owned-value 100)
  (context-provide! ctx restart-state-service 'new)
  (context-add-session-slot! ctx 'replacement-state version: 1 fallback: 'restart-state
                             save: (lambda () owned-value)
                             restore: (lambda (data)
                                        (if fail-restoration? (error "restore failed")
                                          (set! owned-value data))))
  (context-defer! ctx (lambda () (set! owned-value -1))))

(defplugin (restart-dependent ctx)
  "Keeps separate state and restarts with its required provider."
  requires: [session-service restart-state-service]
  (set! dependent-value 20)
  (context-add-session-slot! ctx 'restart-dependent version: 1
                             save: (lambda () dependent-value)
                             restore: (lambda (data) (set! dependent-value data)))
  (context-defer! ctx (lambda () (set! dependent-value -1))))

(def (with-restart-state (proc : :procedure)) => :void
  (call-with-state-directory
   (lambda (directory)
     (with-session-only directory
       (lambda ()
         (activate-plugin! restart-owner)
         (activate-plugin! restart-dependent)
         (restore-session)
         (set! owned-value 42)
         (set! dependent-value 43)
         (proc))))))

(def session-test
  (test-suite "tuna/plugins/session"
    (test-case "restart captures the whole closure before cleanup and restores neutral data"
      (set! fail-restoration? #f)
      (with-restart-state
       (lambda ()
         (restart-plugin! restart-owner restart-replacement)
         (check (service-provider restart-state-service) => 'new)
         (check owned-value => 42)
         (check dependent-value => 43)
         (check (plugin-active? restart-owner) => #f)
         (check (plugin-active? restart-dependent) => #t))))

    (test-case "failed restoration rolls back both provider and dependent saved state"
      (set! fail-restoration? #t)
      (with-restart-state
       (lambda ()
         (check-exception (restart-plugin! restart-owner restart-replacement) Error?)
         (check (service-provider restart-state-service) => 'old)
         (check owned-value => 42)
         (check dependent-value => 43)
         (check (plugin-active? restart-replacement) => #f)
         (check (plugin-active? restart-dependent) => #t)))
      (set! fail-restoration? #f))

    (test-case "a failed capture leaves the plugin active"
      (call-with-state-directory
       (lambda (directory)
         (with-session-only directory
           (lambda ()
             (activate-plugin! unplain-slot)
             (restore-session)
             (check-exception (restart-plugin! unplain-slot unplain-slot) Error?)
             (check (plugin-active? unplain-slot) => #t))))))

    (test-case "the session is saved while idle, and only when it changed"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (on-baton (lambda () (insert "z")))
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
                    => ['buffers 1 [["*scratch*" 2 "%2Ascratch%2A" (on-baton (lambda () (node-id (buffer-root (current-buffer)))))] ]])
             (let (stamp (file-info-last-modification-time (file-info (session-file directory))))
               (thread-sleep! 2.5)
               (check (time->seconds (file-info-last-modification-time
                                      (file-info (session-file directory))))
                      => (time->seconds stamp))))))))

    (test-case "session slots follow their plugins; the oldest name comes first"
      (call-with-state-directory
       (lambda (directory)
         (write-session! directory "(tuna-session 1 (beta 2 \"B\") (alpha 3 \"A\"))")
         (with-session-only directory
           (lambda ()
             (let (restore! (lambda ()
                              (set! restored [])
                              (restore-session)
                              (reverse restored)))
               (activate-plugin! slots-early)
               (activate-plugin! slots-late)
               ;; alpha was registered first; the effective alpha is version 3.
               (check (restore!) => [['alpha 3 "A"] ['beta 2 "B"]])
               ;; Only early's alpha, version 1, remains: the saved version 3
               ;; is skipped.
               (deactivate-plugin! slots-late)
               (check (restore!) => [])
               (deactivate-plugin! slots-early)
               (activate-plugin! slots-late)
               ;; A plugin turned off leaves its slots' latest data in
               ;; memory when no other slot keeps the name: beta holds what
               ;; late saved, and alpha holds early's version 1, which the
               ;; effective alpha (version 3) skips.
               (check (restore!) => [['beta 2 "late beta"]])
               (deactivate-plugin! slots-late)
               (check (restore!) => [])))))))

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
                        => ["*scratch*"])))
             (let (aside (path-expand (car (corrupt-files directory)) directory))
               (check (file-text aside) => content)
               (delete-file aside)))
           ["(tuna-session 1 (buffers 1 ((\"x\" 1 \"x\"))"           ; truncated
            "(tuna-session 1 (buffers 1 #.(exit 3)))"              ; read-time evaluation
            "(tuna-session 1 (layout 1 #!eof))"                    ; not plain data
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
           (check (and (assq 'buffers entries) (assq 'layout entries) #t) => #t)))))

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
