#lang :tuna/prelude
;;; Processes (Emacs `proced`): the `proced` command shows *Processes*, one
;;; row per process, kept current by a source (tuna/lib/background) that
;;; reads /proc every second off the editor thread. A reading is posted
;;; only when what the rows show changed, and a row whose values are equal
;;; stamps nothing, so only the rows that changed are drawn again. Killing
;;; *Processes* (`q` in it), or turning the plugin off, stops the reading.

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/lib/background
        (only-in :tuna/lib/jobs job job-cancel!)
        :tuna/lib/plugin-options
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/stylesheets/contract)
(export proced
        read-processes
        processes-reading)

(def processes-buffer-name "*Processes*")

;; Clock ticks per second in /proc/PID/stat: Linux's USER_HZ, fixed at 100
;; for user space on every architecture Linux supports.
(def ticks-per-second 100)
;; Bytes per page in the stat file's resident set size.
(def page-bytes 4096)

;;; Reading /proc

;; What one /proc/PID/stat says: [pid command state ticks rss-pages], or
;; #f when it does not parse. The command is between the first "(" and the
;; last ")", since it may hold either.
(def (parse-stat (line : :string)) => (Maybe :list)
  (let ((open (string-index line #\())
        (close (string-rindex line #\))))
    (and open close (fx< open close)
         (let (fields (string-split (substring line (fx+ close 2) (string-length line)) #\space))
           (and (fx>= (length fields) 22)
                (let ((pid (string->number (substring line 0 (fx1- open))))
                      (utime (string->number (list-ref fields 11)))
                      (stime (string->number (list-ref fields 12)))
                      (rss (string->number (list-ref fields 21))))
                  (and pid utime stime rss
                       [pid (substring line (fx1+ open) close) (car fields) (+ utime stime) rss])))))))

(def (pid-name? (name : :string)) => :boolean
  (and (fx> (string-length name) 0)
       (andmap char-numeric? (string->list name))))

;; The stat of every process under ROOT, skipping one that went away while
;; being read.
(def (read-stats (root : :string)) => :list
  (filter-map (lambda ((name : :string))
                (and (pid-name? name)
                     (with-catch (lambda (e) #f)
                                 (lambda ()
                                   (let (line (call-with-input-file (path-expand "stat" (path-expand name root))
                                                read-line))
                                     (and (string? line) (parse-stat line)))))))
              (directory-files root)))

;; X, rounded to one decimal, as text.
(def (one-decimal (x : :real)) => :string
  (let* ((tenths (inexact->exact (round (* (max x 0) 10))))
         (whole (quotient tenths 10)))
    (string-append (number->string whole) "." (number->string (- tenths (* whole 10))))))

;; TICKS of processor time as minutes and seconds, as ps shows TIME.
(def (processor-time (ticks : :integer)) => :string
  (let* ((seconds (quotient ticks ticks-per-second))
         (minutes (quotient seconds 60))
         (rest (- seconds (* minutes 60))))
    (string-append (number->string minutes) ":" (if (< rest 10) "0" "") (number->string rest))))

;; PID-TICKS, ((pid . ticks) ...), as a table.
(def (ticks-table (pid-ticks : :list)) => HashTable
  (let (table (make-hash-table-eqv))
    (for-each (lambda ((entry : :pair)) (hash-put! table (car entry) (cdr entry))) pid-ticks)
    table))

;; The reading of STATS taken at time NOW (seconds), after PREVIOUS (#f
;; for none): ((row ...) . (NOW . ((pid . ticks) ...))). A row is what one
;; process shows, [pid state %cpu rss-mib time command], each formatted, so
;; rows compare equal exactly when they would look the same; the rest
;; carries the counters the next reading needs for %CPU: the processor
;; time used since PREVIOUS over the time passed, 0.0 without one.
(def (processes-reading (stats : :list) (now : :real) (previous :? :pair)) => :pair
  (let* ((before (and previous (cdr previous)))
         (elapsed (and before (- now (car before))))
         (ticks-before (ticks-table (if before (cdr before) [])))
         (sorted (list-sort (lambda (a b) (< (car a) (car b))) stats))
         (rows (map (lambda (stat)
                      (match stat
                        ([pid command state ticks rss]
                         (let (was (hash-get ticks-before pid))
                           [pid state
                                (one-decimal (if (and was elapsed (> elapsed 0))
                                               (/ (* 100. (- ticks was)) (* elapsed ticks-per-second))
                                               0))
                                (one-decimal (/ (* rss page-bytes) 1048576.))
                                (processor-time ticks)
                                command]))))
                    sorted)))
    (cons rows (cons now (map (lambda (stat) (cons (car stat) (list-ref stat 3))) sorted)))))

;; The processes under ROOT, after the reading PREVIOUS: a source's read.
(def (read-processes (root : :string) (previous :? :pair)) => :pair
  (processes-reading (read-stats root) (time->seconds (current-time)) previous))

;; Whether two readings show the same rows.
(def (same-rows? (a : :pair) (b : :pair)) => :boolean
  (equal? (car a) (car b)))

;;; *Processes*

(def columns '("PID" "STAT" "%CPU" "RSS MiB" "TIME" "COMMAND"))
(def column-classes '("proced-pid" "proced-state" "proced-cpu" "proced-memory" "proced-time" "proced-command"))

(def (render-cells (values : :list)) => :list
  (map (lambda (class value) `(span (@ (class ,class)) ,(if (number? value) (number->string value) value)))
       column-classes values))

;; The plugin's state: the list node, its header, and a row node per pid.
(defclass proced-state ((processes   :? buffer)   ; *Processes*, while it exists
                        (list-node   :? node)     ; its root node
                        (header-node :? node)
                        (rows        : HashTable) ; pid -> row node
                        (reading-job :? job))     ; the source's job, while it reads
  final: #t)

;; On the baton: show READING's rows, changing only the rows that differ,
;; and the list's children only when processes came or went.
(def (update-rows! (self : proced-state) (reading : :pair)) => :void
  (when self.list-node
    (let ((rows (car reading))
          (table self.rows)
          (seen (make-hash-table-eqv))
          (changed? #f))
      (for-each (lambda (row)
                  (let* ((pid (car row))
                         (n (hash-get table pid)))
                    (hash-put! seen pid #t)
                    (if n
                      (set-node-attribute! n 'row row)
                      (begin
                        (hash-put! table pid (new-node 'proced-row attributes: [(cons 'row row)]))
                        (set! changed? #t)))))
                rows)
      (for-each (lambda (pid)
                  (unless (hash-key? seen pid)
                    (hash-remove! table pid)
                    (set! changed? #t)))
                (hash-keys table))
      (when changed?
        (set-node-children! self.list-node
                            (cons self.header-node (map (lambda (row) (hash-ref table (car row))) rows)))))))

;; Stop reading, and forget the buffer's nodes.
(def (stop-reading! (self : proced-state)) => :void
  (let (reading-job self.reading-job)
    (when reading-job (job-cancel! reading-job)))
  (set! self.reading-job #f)
  (set! self.processes #f)
  (set! self.list-node #f)
  (set! self.header-node #f)
  (hash-clear! self.rows))

;; Show *Processes* in the selected view, making it and starting to read
;; the first time. KEYMAP is its keymap.
(def (show-processes! (self : proced-state) (ctx : context) (keymap : entry-table)) => :void
  (unless self.processes
    (let* ((header (new-node 'proced-header))
           (root (new-node 'proced children: [header] keymap: keymap))
           (b (new-buffer processes-buffer-name root)))
      (set! self.list-node root)
      (set! self.header-node header)
      (set! self.processes b)
      (context-add-buffer! ctx b)
      (set! self.reading-job
        (context-start-source! ctx 'processes
                               every: (/ (plugin-option proced 'interval) 1000.)
                               input: (plugin-option proced 'root)
                               read: read-processes
                               compare: same-rows?
                               apply: (lambda (reading) (update-rows! self reading))))))
  (set-view-buffer (selected-view) self.processes))

(defplugin (proced ctx)
  "M-x proced: *Processes*, one row per process, read from /proc every second."
  requires: [commands-service input-service buffers-service layout-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (context-define-node-kind! ctx 'proced doc: "A list of processes, one row each." items: 'children)
  (context-define-node-kind! ctx 'proced-header doc: "The names of a process list's columns." items: 'whole)
  (context-define-node-kind! ctx 'proced-row doc: "One process: its pid, state, %CPU, memory, time and command."
                             items: 'whole
                             project: (lambda (n) (string-join (map (lambda (v) (if (number? v) (number->string v) v))
                                                                    (node-attribute n 'row))
                                                               " ")))
  (context-define-node-renderer! ctx 'proced (lambda (n children) `(div (@ (class "proced")) ,@children)))
  (context-define-node-renderer! ctx 'proced-header
                                 (lambda (n children) `(div (@ (class "proced-row proced-header")) ,@(render-cells columns))))
  (context-define-node-renderer! ctx 'proced-row
                                 (lambda (n children) `(div (@ (class "proced-row")) ,@(render-cells (node-attribute n 'row)))))
  (using ((self (proced-state processes: #f list-node: #f header-node: #f rows: (make-hash-table-eqv) reading-job: #f)
                : proced-state)
          (keymap (new-keymap) : entry-table))
    (context-add-hook! ctx kill-buffer-hook 'proced
                       (lambda (b) (when (eq? b self.processes) (stop-reading! self))))
    (define-command ctx (proced) "Show *Processes*, one row per process, kept current."
      (show-processes! self ctx keymap))
    (define-command ctx (quit-proced) "Kill *Processes*, which stops reading the processes."
      (let (b self.processes)
        (when b (kill-buffer b))))
    (keymap-set-in keymap "q" 'quit-proced)))

(defplugin-options proced
  (root "/proc" "The directory to read processes from, as Linux's /proc." string-type)
  (interval 1000 "Milliseconds between readings of the processes." (integer-type 10 60000)))
