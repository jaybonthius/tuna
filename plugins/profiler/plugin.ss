#lang :tuna/prelude
;;; The profiler (docs/briefs/2026-10-profiler.md, agents/plans/profiler.md):
;;; where the time goes for each input item, from the key to the paint.
;;; Nothing in Tuna knows it: it listens to general hooks, and turning it
;;; off removes every listener with its receipt.
;;;
;;; Two plugins:
;;; - `profiler` records: while it is on, every input item's span tree
;;;   (spans.ss) is written, once the item's screens are painted, as one
;;;   JSON object per line to spans-<time>.jsonl in the profile folder
;;;   ($XDG_STATE_HOME/tuna/profile by default), and forgotten. A file past
;;;   `file-size` bytes is followed by a new one; items shorter than
;;;   `minimum` milliseconds are not written.
;;; - `profiler-commands` turns it on and off (`profiler-mode`) and runs the
;;;   sampler (sampler.ss): `profiler-start`, then `profiler-stop` writes,
;;;   off the editor thread, samples-<time>.folded, a `stack;of;frames
;;;   count` line per stack, each starting with the input item it was
;;;   taken during.

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :gerbil/runtime/thread spawn-thread)
        (only-in :std/encoding/json json->string)
        (only-in :std/time/date current-date date->string)
        :tuna/kernel
        :tuna/version
        :tuna/configuration
        :tuna/lib/plugin-options
        :tuna/lib/jobs
        (only-in :tuna/lib/background off-thread)
        :tuna/plugins/clients/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/web/contract
        ./clock
        ./spans
        ./sampler)
(export profiler
        profiler-commands
        profile-folder)

;; Note a failure on standard error: the profiler never raises into the
;; code it follows.
(def (warn (text : :string) (e : :t)) => :void
  (let (port (current-error-port))
    (display "tuna/profiler: " port)
    (display text port)
    (display (exception-summary e) port)
    (newline port)))

;;; Where results go

;; The profile folder: the folder option, or $XDG_STATE_HOME/tuna/profile
;; (~/.local/state/tuna/profile when that is unset or relative).
(def (profile-folder) => :string
  (let (given (plugin-option profiler 'folder))
    (if (string-empty? given)
      (let (xdg (getenv "XDG_STATE_HOME" ""))
        (path-expand "tuna/profile"
                     (if (string-prefix? "/" xdg) xdg (path-expand ".local/state" (getenv "HOME" "/")))))
      (path-expand given))))

;; A new file in FOLDER named PREFIX-<UTC time>SUFFIX, made unique with a
;; counter.
(def (new-profile-path (folder : :string) (prefix : :string) (suffix : :string)) => :string
  (let (stamp (date->string (current-date) "%Y%m%dT%H%M%SZ"))
    (create-directory* folder)
    (let lp ((n 0))
      (let (path (path-expand (string-append prefix "-" stamp (if (fxzero? n) "" (string-append "-" (number->string n)))
                                             suffix)
                              folder))
        (if (file-exists? path) (lp (fx1+ n)) path)))))

;;; The writer: a thread of the profiler's own

;; Writes each finished tree it is sent as a line, and every second
;; finishes trees nothing happened to; stops when sent 'stop.
(defclass span-writer ((folder    : :string)
                       (path      :? :string)
                       (port      : :t)          ; the open file, or #f
                       (written   : :fixnum)
                       (file-size : :fixnum)
                       (minimum   : :flonum))
  final: #t)

(def (header-line) => :string
  (let (h (make-hash-table))
    (hash-put! h "tuna" (tuna-version))
    (hash-put! h "host" (host-name))
    (hash-put! h "started" (inexact->exact (floor (* 1000 (time->seconds (current-time))))))
    (hash-put! h "units" "milliseconds of the server's monotonic clock from the item's arrival; bytes")
    (:- (json->string h) :string)))

(def (write-line! (self : span-writer) (line : :string)) => :void
  (when (or (not self.port) (fx> self.written self.file-size))
    (when self.port (close-port self.port))
    (let (path (new-profile-path self.folder "spans" ".jsonl"))
      (set! self.path path)
      (set! self.port (open-output-file [path: path append: #t]))
      (set! self.written 0)
      (let (header (header-line))
        (display header self.port)
        (newline self.port)
        (set! self.written (fx+ self.written (fx1+ (string-length header)))))))
  (let (port self.port)
    (display line port)
    (newline port)
    (force-output port)
    (set! self.written (fx+ self.written (fx1+ (string-length line))))))

(def (span-writing-thread (self : span-writer) (r : recorder)) => :void
  (let lp ()
    (match (thread-receive 1. 'tick)
      ('stop
       (when self.port (close-port self.port)))
      ('tick
       (with-catch (lambda (e) (warn "finishing trees failed: " e))
                   (lambda () (recorder-expire! r)))
       (lp))
      (tree
       (with-catch (lambda (e) (warn "writing a tree failed: " e))
                   (lambda ()
                     (when (fl>= (or (span-duration (item-tree-root tree)) 0.) self.minimum)
                       (write-line! self (tree->json tree)))))
       (lp)))))

;;; Describing input

(def (tab-of (c :? client)) => :string
  (if c (let (id (client-id c)) (substring id 0 (fxmin 8 (string-length id)))) "none"))

;; ITEM, a key, pointer, scroll or paste event, as details: its kind and
;; what it was.
(def (describe-item (item : :t)) => :list
  (cond
   ((key-event? item)
    [(cons 'kind "key")
     (cons 'key (string-append (if (key-event-ctrl? item) "C-" "")
                               (if (or (key-event-alt? item) (key-event-meta? item)) "M-" "")
                               (if (and (key-event-shift? item) (fx> (string-length (key-event-key item)) 1)) "S-" "")
                               (key-event-key item)))])
   ((pointer-event? item)
    [(cons 'kind "pointer") (cons 'pointer (symbol->string (pointer-event-kind item)))
     (cons 'button (pointer-event-button item))])
   ((scroll-event? item) [(cons 'kind "scroll")])
   ((paste-event? item) [(cons 'kind "paste") (cons 'characters (string-length (paste-event-text item)))])
   (else [(cons 'kind "other")])))

;;; The recorder plugin

;; The recorder while `profiler` is on, for the sampler's labels.
(def active-recorder #f)

(def (current-item-label) => (Maybe :string)
  (let (r active-recorder)
    (and r (recorder-current-label r))))

;; Run THUNK, a listener's work; a failure is logged, never raised into
;; the code announcing the event.
(def (listening (what : :symbol) (thunk : :procedure)) => :void
  (with-catch (lambda (e) (warn (string-append "following " (symbol->string what) " failed: ") e))
              thunk))

;; Depths that put the recorder's callbacks first and last on a hook.
(def first-depth -1000000)
(def last-depth 1000000)

(defplugin (profiler ctx)
  "Writes each input item's span tree, from the key to the paint, to the profile folder."
  ;; The module's contracts: hooks of the commands, renderer and web
  ;; contracts; the configuration only for profiler-commands.
  optional: [commands-service renderer-service page-service configuration-service]
  (let* ((writer (span-writer folder: (profile-folder) path: #f port: #f written: 0
                              file-size: (plugin-option profiler 'file-size)
                              minimum: (exact->inexact (plugin-option profiler 'minimum))))
         (thread #f)
         (r (new-recorder finish: (lambda (tree) (let (t thread) (when t (thread-send t tree)))))))
    (set! thread (spawn-thread (lambda () (span-writing-thread writer r)) 'tuna-profiler-writer))
    (set! active-recorder r)
    (context-defer! ctx (lambda ()
                          (set! active-recorder #f)
                          (recorder-flush! r)
                          (thread-send thread 'stop)
                          (thread-join! thread 5 #f)))
    ;; Input.
    (context-add-hook! ctx input-arrived-hook 'profiler
                       (lambda (c (sequence : :fixnum) item)
                         (listening 'input-arrived
                                    (lambda () (recorder-arrived! r c (tab-of c) sequence (describe-item item))))))
    (context-add-hook! ctx input-resolved-hook 'profiler
                       (lambda (c (sequence : :fixnum) item name)
                         (listening 'input-resolved
                                    (lambda () (recorder-resolved! r c (tab-of c) sequence (describe-item item) name)))))
    ;; Tasks and commands.
    (context-add-hook! ctx task-started-hook 'profiler
                       (lambda ((id : :fixnum) (name : :symbol))
                         (listening 'task-started (lambda () (recorder-task-started! r id name)))))
    (context-add-hook! ctx task-finished-hook 'profiler
                       (lambda ((id : :fixnum) (name : :symbol) (how : :symbol))
                         (listening 'task-finished (lambda () (recorder-task-finished! r id how)))))
    (for-each
     (lambda ((spec : :list))
       (match spec
         ([h which edge name depth]
          (context-add-hook! ctx h name
                             (lambda ()
                               (listening which
                                          (lambda ()
                                            (recorder-command-hook! r (current-task-id) which edge
                                                                    (and (eq? edge 'last) (eq? which 'pre-command)
                                                                         (this-command))))))
                             depth: depth))))
     [[pre-command-hook 'pre-command 'first 'profiler-first first-depth]
      [pre-command-hook 'pre-command 'last 'profiler-last last-depth]
      [post-command-hook 'post-command 'first 'profiler-first first-depth]
      [post-command-hook 'post-command 'last 'profiler-last last-depth]])
    ;; Jobs.
    (context-add-hook! ctx job-started-hook 'profiler
                       (lambda ((id : :fixnum) key)
                         (listening 'job-started (lambda () (recorder-job-started! r (current-task-id) id key)))))
    (context-add-hook! ctx job-finished-hook 'profiler
                       (lambda ((id : :fixnum) key (how : :symbol))
                         (listening 'job-finished (lambda () (recorder-job-finished! r id how)))))
    ;; Redraws and screens.
    (context-add-hook! ctx redraw-started-hook 'profiler
                       (lambda (c)
                         (listening 'redraw-started (lambda () (recorder-redraw-started! r c (tab-of c))))))
    (context-add-hook! ctx redraw-finished-hook 'profiler
                       (lambda (c (drawn : :fixnum) (reused : :fixnum) html)
                         (listening 'redraw-finished
                                    (lambda () (recorder-redraw-finished! r c drawn reused (html-size html))))))
    (context-add-hook! ctx screen-ready-hook 'profiler
                       (lambda (c revision (through : :fixnum))
                         (listening 'screen-ready (lambda () (recorder-screen-ready! r c revision through)))))
    (context-add-hook! ctx screen-sent-hook 'profiler
                       (lambda (c (stream : :fixnum) (count : :fixnum) (revision : :fixnum) (through : :fixnum)
                                  (bytes : :fixnum))
                         (listening 'screen-sent (lambda () (recorder-screen-sent! r c stream count revision bytes)))))
    (context-add-hook! ctx screen-applied-hook 'profiler
                       (lambda (c (stream : :fixnum) (count : :fixnum) (measurements : :list))
                         (listening 'screen-applied
                                    (lambda () (recorder-screen-applied! r c stream count measurements)))))))

(defplugin-options profiler
  (folder "" "The folder profiles are written to; empty for $XDG_STATE_HOME/tuna/profile."
          string-type)
  (file-size 67108864 "Bytes past which the profiler starts a new spans file."
             (integer-type 1024 1073741824))
  (minimum 0 "Milliseconds below which an input item's tree is not written; 0 writes every item."
           (integer-type 0 3600000))
  (sample-interval 1 "Milliseconds between the sampler's samples."
                   (integer-type 1 1000)))

;;; The commands plugin

;; Turn the profiler on or off, as `profiler-mode` does. Returns the
;; message it shows.
(def (toggle-profiler!) => :string
  (if (plugin-active? profiler)
    (begin
      (deactivate-plugin! profiler)
      "Profiler off")
    (begin
      (activate-plugin! profiler)
      (string-append "Profiler on: span trees go to " (profile-folder)))))

;; Write SAMPLES, as sampler-stop! returns them, to a new samples file in
;; FOLDER and return its path. Slow for a long run: never call it on the
;; editor thread.
(def (write-samples (samples : :list) (folder : :string)) => :string
  (let (path (new-profile-path folder "samples" ".folded"))
    (call-with-output-file path
      (lambda (port)
        (for-each (lambda ((line : :string)) (display line port) (newline port))
                  (folded-lines samples))))
    path))

(defplugin (profiler-commands ctx)
  "M-x profiler-mode turns the profiler on and off; M-x profiler-start and profiler-stop sample call stacks."
  requires: [commands-service]
  optional: [configuration-service renderer-service page-service]
  ;; Turned off while sampling: the samples are written on a thread of
  ;; their own, since no command waits for them.
  (context-defer! ctx (lambda ()
                        (when (sampler-running?)
                          (let ((samples (sampler-stop!))
                                (folder (profile-folder)))
                            (spawn-thread (lambda () (write-samples samples folder))
                                          'tuna-profiler-samples)))))
  (define-command ctx (profiler-mode) "Turn the profiler, which writes each input item's span tree, on or off."
    (message (toggle-profiler!)))
  (define-command ctx (profiler-start) "Start sampling call stacks, until profiler-stop."
    (if (sampler-running?)
      (message "The sampler is already running")
      (begin
        (sampler-start! (/ (plugin-option profiler 'sample-interval) 1000.) current-item-label)
        (message "Sampling call stacks; M-x profiler-stop writes them"))))
  ;; The samples are written off the editor thread; the command waits
  ;; there (off-thread) while the editor goes on.
  (define-command ctx (profiler-stop) "Stop sampling call stacks, and write them to the profile folder."
    (if (sampler-running?)
      (let (samples (sampler-stop!))
        (message "Writing samples…")
        (message (string-append "Samples written to "
                                (off-thread (lambda ((folder : :string)) (write-samples samples folder))
                                            (profile-folder)))))
      (message "The sampler is not running"))))
