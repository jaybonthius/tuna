;;; Integration: an idle editor does nothing. With the web transport and
;;; two tabs whose streams are open, once start-up has settled, seconds
;;; pass with no task run and no screen drawn or sent; then a key typed in
;;; one tab is drawn in both and saved. The session and autosave save after
;;; a change, not on a repeating timer, and the transport forgets no tab
;;; that has a stream open, so neither runs a task while nothing happens.
(import :std/error
        :std/io
        :std/test
        :std/time/timeout
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/settings/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/web/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/session/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/autosave/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin
        :tuna/plugins/scrolling/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/editing/plugin
        :tuna/plugins/minibuffer/plugin
        "../../plugins/web/tests/support/web-client")
(export idle-test)

;; Tasks started, and views drawn (each drawn view reads its buffer's
;; show-status-line, through every settings scope), since last reset.
(def tasks 0)
(def views-drawn 0)

(defplugin (idle-counters ctx)
  "Counts the tasks started and the views drawn."
  requires: [settings-service]
  (context-add-hook! ctx task-started-hook 'idle-counters
                     (lambda (id name) (set! tasks (+ tasks 1))))
  (context-add-setting-scope! ctx 'idle-counters
                              (lambda (s)
                                (when (eq? s show-status-line)
                                  (set! views-drawn (+ views-drawn 1)))
                                #f)
                              priority: 1000))

(def idle-plugins
  [commands keys web-transport echo-area rope-text-store settings session buffers autosave
   layout minibuffer view-commands scrolling html-renderer editing idle-counters])

;; Milliseconds after a task before the session is saved, and before a
;; page's tab is forgotten unless a stream is open: the first passes before
;; the idle seconds, the second within them.
(def save-delay-ms 200)
(def tab-grace-ms 2000)

(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-idle-test-" (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

(def (with-idle-tuna directory thunk)
  (set-plugin-options! session [(cons 'save-delay save-delay-ms)])
  (set-plugin-options! web-transport [(cons 'tab-grace tab-grace-ms)])
  (try
   (parameterize ((session-state-directory directory))
     (with-web-tuna idle-plugins thunk))
   (finally
    (set-plugin-options! session [])
    (set-plugin-options! web-transport []))))

(def (wait-until ready?)
  (let lp ((tries 300))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))

;; Whether TEXT, read from a screen stream, holds a screen.
(def (has-screen? text) (and (string-search "data-revision=\"" text) #t))

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

;; Read STREAM's screen, then confirm it as TAB's page does.
(def (confirm-screen! stream tab)
  (post-applied (applied-path (read-until stream has-screen?)) tab: tab))

;; What STREAM sends within SECONDS, or "" if nothing.
(def (sent-within stream seconds)
  (Socket-set-input-timeout! stream (IOTimeout seconds))
  (begin0 (with-catch (lambda (e) "") (lambda () (read-until stream has-screen?)))
    (Socket-set-input-timeout! stream (IOTimeout 5))))

(def (file-text path)
  (if (file-exists? path)
    (call-with-input-file [path: path char-encoding: 'UTF-8]
      (lambda (port)
        (let (content (read-line port #f))
          (if (eof-object? content) "" content))))
    ""))

(def idle-test
  (test-suite "integration: an idle editor runs no task and draws nothing"
    (test-case "two tabs: idle seconds run no task and draw no screen; a key after them is drawn and saved"
      (call-with-state-directory
       (lambda (directory)
         (with-idle-tuna directory
           (lambda ()
             (let* ((a (current-tab))
                    (a-stream (open-screen-stream tab: a))
                    (b (new-tab!))
                    (b-stream (open-screen-stream tab: b)))
               (confirm-screen! a-stream a)
               (confirm-screen! b-stream b)
               ;; Settle: the session saves after the start-up tasks.
               (thread-sleep! 1.)
               (set! tasks 0)
               (set! views-drawn 0)
               (let (session-file (path-expand "session.ss" directory))
                 (check (file-exists? session-file) => #t)
                 (let (saved (file-info-last-modification-time (file-info session-file)))
                   (thread-sleep! 3.)
                   (check tasks => 0)
                   (check views-drawn => 0)
                   (check (sent-within a-stream 0.2) => "")
                   (check (sent-within b-stream 0.2) => "")
                   (check (time->seconds (file-info-last-modification-time (file-info session-file)))
                          => (time->seconds saved))))
               ;; A key typed in A is drawn in both tabs, and saved.
               (post-key "q" tab: a)
               (check (and (string-search "q<span class=\"cursor\">" (read-until a-stream (cut string-search "q<span" <>)))
                           #t)
                      => #t)
               (check (and (string-search "q<span class=\"cursor\">" (read-until b-stream (cut string-search "q<span" <>)))
                           #t)
                      => #t)
               (check (> tasks 0) => #t)
               (check (> views-drawn 0) => #t)
               (check (wait-until (lambda () (equal? (file-text (path-expand "autosave/%2Ascratch%2A" directory)) "q")))
                      => #t)
               (Socket-close a-stream)
               (Socket-close b-stream)))))))))
