;;; Integration: the proced plugin through the web transport, with a
;;; /proc fixture read every 20 ms. A change to two processes draws exactly
;;; their two rows, with one tab and with two (tabs share the rows'
;;; pieces); while nothing changes, no task runs, nothing is drawn and
;;; nothing is sent; killing *Processes* stops the reading; processes that
;;; come and go keep the rows equal to the processes.
(import (only-in :gerbil/runtime/thread spawn-thread)
        :std/error
        :std/io
        :std/test
        :std/time/timeout
        :tuna/kernel
        :tuna/lib/memo
        :tuna/lib/plugin-options
        :tuna/plugins/commands/contract
        :tuna/plugins/buffers/contract
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
        :tuna/plugins/proced/plugin
        "../../plugins/web/tests/support/web-client"
        "../../plugins/proced/tests/support/proc-fixture")
(export proced-test)

(def tasks 0)

(defplugin (task-counter ctx)
  "Counts the tasks started."
  (context-add-hook! ctx task-started-hook 'proced-test (lambda (id name) (set! tasks (+ tasks 1)))))

;; The keys of the memo pieces drawn (not reused) since last reset.
(def drawn [])

(def proced-plugins
  [commands keys web-transport echo-area rope-text-store settings session buffers autosave
   layout minibuffer view-commands scrolling html-renderer editing proced task-counter])

(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-proced-test-" (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

;; Run THUNK with Tuna reading processes from the fixture ROOT every 20
;; ms, observing every piece drawn: the loop thread and its tasks inherit
;; the observer.
(def (with-proced-tuna root thunk)
  (set-plugin-options! session [(cons 'save-delay 200)])
  (set-plugin-options! web-transport [(cons 'tab-grace 2000)])
  (set-plugin-options! proced [(cons 'root root) (cons 'interval 20)])
  (try
   (call-with-state-directory
    (lambda (directory)
      (parameterize ((session-state-directory directory)
                     (current-memo-draw-observer (lambda (key) (set! drawn (cons key drawn)))))
        (with-web-tuna proced-plugins thunk))))
   (finally
    (set-plugin-options! session [])
    (set-plugin-options! web-transport [])
    (set-plugin-options! proced []))))

;; THUNK's value, run as a task on the baton; raises after SECONDS, so a
;; stuck loop fails the test instead of hanging it. Never call it from
;; THUNK: a task cannot wait for another.
(def (on-baton thunk seconds: (seconds 10))
  (with-catch
   (lambda (e) (raise (if (uncaught-exception? e) (uncaught-exception-reason e) e)))
   (lambda () (thread-join! (spawn-thread (lambda () (call-on-editor-loop thunk)) 'on-baton) seconds))))

(def (has-screen? text) (and (string-search "data-revision=\"" text) #t))

(def (string-search-from needle text start)
  (let (found (string-search needle (substring text start (string-length text))))
    (and found (+ found start))))

(def (string-split-on text separator)
  (let (at (string-search separator text))
    (if at
      (cons (substring text 0 at)
            (string-split-on (substring text (+ at (string-length separator)) (string-length text)) separator))
      [text])))

;; The /applied path of the last screen in TEXT, as its page posts it.
(def (applied-path text)
  (let lp ((at 0) (last #f))
    (let (found (string-search-from "/applied?stream=" text at))
      (if found
        (lp (+ found 1) found)
        (let (end (string-index text #\' last))
          (string-join (string-split-on (substring text last end) "&amp;") "&"))))))

;; Read STREAM until (DONE? text) holds of a screen, then confirm the last
;; screen read as TAB's page does.
(def (read-and-confirm! stream tab done?)
  (let (text (read-until stream (lambda (text) (and (has-screen? text) (done? text))) seconds: 10))
    (unless (and (has-screen? text) (done? text))
      (error "The screen expected never came"))
    (post-applied (applied-path text) tab: tab)
    text))

;; What STREAM sends within SECONDS, or "" if nothing.
(def (sent-within stream seconds)
  (Socket-set-input-timeout! stream (IOTimeout seconds))
  (begin0 (with-catch (lambda (e) "") (lambda () (read-until stream has-screen?)))
    (Socket-set-input-timeout! stream (IOTimeout 5))))

;; On the baton: *Processes*'s row nodes.
(def (row-nodes)
  (let (b (get-buffer "*Processes*"))
    (if b
      (filter (lambda (n) (eq? (node-kind n) 'proced-row)) (node-children (buffer-root b)))
      [])))

;; The ids of *Processes*'s row nodes, and their pids.
(def (row-ids) (on-baton (lambda () (map node-id (row-nodes)))))
(def (row-pids) (on-baton (lambda () (map (lambda (n) (car (node-attribute n 'row))) (row-nodes)))))

;; How many distinct row pieces were drawn since DRAWN was reset.
(def (rows-drawn ids)
  (let (seen (make-hash-table))
    (for-each (lambda (key)
                (when (and (pair? key) (eq? (car key) 'node) (memv (caddr key) ids))
                  (hash-put! seen key #t)))
              drawn)
    (hash-length seen)))

(def (fixture-with-processes count)
  (let (root (make-proc-fixture))
    (let lp ((pid 1))
      (when (<= pid count)
        (write-process! root pid command: (string-append "process-" (number->string pid)))
        (lp (+ pid 1))))
    root))

(def (wait-until ready? seconds: (seconds 5))
  (let lp ((tries (* seconds 100)))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))

(def proced-test
  (test-suite "integration: proced draws only the rows that changed, and idles"
    (test-case "two processes change: two rows drawn, with one tab and with two; idle sends nothing"
      (let (root (fixture-with-processes 10))
        (try
         (with-proced-tuna root
           (lambda ()
             (let* ((a (current-tab))
                    (a-stream (open-screen-stream tab: a)))
               (read-and-confirm! a-stream a (lambda (text) #t))
               (on-baton (lambda () (call-command 'proced)))
               (read-and-confirm! a-stream a (cut string-search "process-10<" <>))
               (let (ids (row-ids))
                 (check (length ids) => 10)
                 ;; One tab.
                 (thread-sleep! 0.2)
                 (set! drawn [])
                 (write-process! root 3 command: "process-3" state: "R")
                 (write-process! root 5 command: "process-5" rss: 2560)
                 (read-and-confirm! a-stream a (lambda (text) (and (string-search ">R<" text)
                                                                   (string-search ">10.0<" text))))
                 (check (rows-drawn ids) => 2)
                 ;; Two tabs: the rows' pieces are shared.
                 (let* ((b (new-tab!))
                        (b-stream (open-screen-stream tab: b)))
                   (read-and-confirm! b-stream b (cut string-search "process-10<" <>))
                   (thread-sleep! 0.2)
                   (set! drawn [])
                   (write-process! root 4 command: "process-4" state: "D")
                   (write-process! root 6 command: "process-6" rss: 5120)
                   (read-and-confirm! a-stream a (lambda (text) (and (string-search ">D<" text)
                                                                     (string-search ">20.0<" text))))
                   (read-and-confirm! b-stream b (lambda (text) (and (string-search ">D<" text)
                                                                     (string-search ">20.0<" text))))
                   (check (rows-drawn ids) => 2)
                   ;; Idle: about 150 readings, none different.
                   (thread-sleep! 0.5)
                   (set! tasks 0)
                   (set! drawn [])
                   (thread-sleep! 3.)
                   (check tasks => 0)
                   (check drawn => [])
                   (check (sent-within a-stream 0.2) => "")
                   (check (sent-within b-stream 0.2) => "")
                   (Socket-close b-stream)))
               (Socket-close a-stream))))
         (finally (delete-proc-fixture root)))))

    (test-case "killing *Processes* (quit-proced, q) stops reading"
      (let (root (fixture-with-processes 3))
        (try
         (with-proced-tuna root
           (lambda ()
             (on-baton (lambda () (call-command 'proced)))
             (check (wait-until (lambda () (= (length (row-ids)) 3))) => #t)
             (on-baton (lambda () (call-command 'quit-proced)))
             (check (on-baton (lambda () (get-buffer "*Processes*"))) => #f)
             ;; A source still reading would now fail, and report it in a task.
             (delete-proc-fixture root)
             (thread-sleep! 0.2)
             (set! tasks 0)
             (thread-sleep! 0.5)
             (check tasks => 0)))
         (finally (delete-proc-fixture root)))))

    (test-case "processes that come and go keep one row per process"
      (let (root (fixture-with-processes 20))
        (try
         (with-proced-tuna root
           (lambda ()
             (on-baton (lambda () (call-command 'proced)))
             (check (wait-until (lambda () (= (length (row-ids)) 20))) => #t)
             (let lp ((cycle 0) (next 21))
               (when (< cycle 20)
                 (remove-process! root (- next 20))
                 (write-process! root next command: (string-append "process-" (number->string next)))
                 (thread-sleep! 0.01)
                 (lp (+ cycle 1) (+ next 1))))
             (let (expected (let lp ((pid 40) (out [])) (if (< pid 21) out (lp (- pid 1) (cons pid out)))))
               (check (wait-until (lambda () (equal? (row-pids) expected))) => #t))))
         (finally (delete-proc-fixture root)))))))
