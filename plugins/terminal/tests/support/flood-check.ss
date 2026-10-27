;;; A manual check of heavy output, run by `make terminal-flood-check`
;;; (never by `make test`: it takes a minute and measures, it does not
;;; judge). It starts the terminal plugin in a fresh kernel with a real
;;; helper running sh, and runs one flood in the terminal, shown in the
;;; selected view: `seq 1 2000000`, or `cat` of a file of about 50 MB. While
;;; it runs, a probe thread asks the editor loop to run an empty task every
;;; 10 ms, as a key typed in another view would, and another reads Tuna's
;;; resident memory every 50 ms. It prints how long the flood took, how
;;; long after the program ended Tuna had parsed its output (the backlog),
;;; how long the editor took to answer the probe (median, 99th percentile,
;;; worst), and the most memory Tuna held.
;;;
;;; Usage: gxi flood-check.ss seq|cat [FILE]
;;; FILE, for cat, is made (base64 of random bytes) when it is missing.
;;;
;;; gxi flood-check.ss many on|off instead runs `seq 1 300000` in eight
;;; terminals, each keeping its 5 MB of scrollback, and prints the memory
;;; Tuna and the helpers hold, then again ten seconds after the output
;;; stopped, with terminal-compress-after 2 (on) or #f (off).
(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/terminal/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/terminal/plugin
        (only-in :tuna/lib/memo set-memo-checking!)
        (only-in :tuna/lib/plain-data set-plain-data-checking!)
        "../../../keys/tests/support/keys"
        "helpers"
        "terminals")
(export main)

(def (now) => :real (time->seconds (current-time)))

;; When the mirror parsed the title the flood ends with.
(def titled #f)

(defplugin (flood-end-recorder ctx)
  "Records when a terminal's title says the flood ended."
  (context-add-hook! ctx terminal-title-hook 'flood-check
                     (lambda (term title) (when (equal? title "FLOOD-END") (set! titled (now))))))

;; Tuna's resident memory, in MiB.
(def (resident-mib) => :real
  (let* ((lines (call-with-input-file "/proc/self/status" (lambda (port) (read-all port read-line))))
         (line (find (cut string-prefix? "VmRSS:" <>) lines))
         (kb (and line (string->number (car (filter (lambda (s) (not (string-empty? s)))
                                                    (cdr (string-split line #\space))))))))
    (if kb (/ kb 1024.) 0.)))

(def (percentile (sorted : :list) (p : :real)) => :real
  (if (null? sorted) 0. (list-ref sorted (min (- (length sorted) 1) (inexact->exact (floor (* p (length sorted))))))))

(def (milliseconds (seconds : :real)) => :string
  (number->string (/ (round (* seconds 10000.)) 10.)))

(def (seconds-text (seconds : :real)) => :string
  (number->string (/ (round (* seconds 100.)) 100.)))

(def (ensure-file! (path : :string)) => :void
  (unless (file-exists? path)
    (let (p (open-process [path: "/bin/sh" arguments: ["-c" (string-append "head -c 37000000 /dev/urandom | base64 > " path)]]))
      (process-status p)
      (close-port p))))

;; Whether the many check compresses.
(def compress? #t)

(defplugin (compression-setting ctx)
  "Compresses quiet terminals after two seconds, or never."
  requires: [settings-service]
  (context-set-setting! ctx terminal-compress-after (and compress? 2)))

(def (helpers-kib) => :integer
  (apply + (map resident-kib (helper-pids))))

(def (many-terminals) => :void
  (with-terminals
   (lambda (folder)
     (start-kernel
      (lambda ()
        (set-memo-checking! #f)
        (set-plain-data-checking! #f)
        (start-editor-loop!)
        (let lp ((i 0))
          (when (< i 8)
            (on-editor (lambda () (call-command 'terminal-new)))
            (thread-sleep! 0.5)
            (paste "seq 1 300000")
            (press "RET")
            (thread-sleep! 1.5)
            (lp (+ i 1))))
        (thread-sleep! 1)
        (##gc)
        (displayln "eight terminals, compression " (if compress? "after 2 s" "off"))
        (displayln "  at once: Tuna " (round (resident-mib)) " MiB, helpers " (round (/ (helpers-kib) 1024.)) " MiB")
        (thread-sleep! 10)
        (##gc)
        (displayln "  10 s later: Tuna " (round (resident-mib)) " MiB, helpers " (round (/ (helpers-kib) 1024.)) " MiB"))
      [compression-setting]))))

(def (main kind . rest)
  (when (equal? kind "many")
    (set! compress? (not (equal? rest ["off"])))
    (many-terminals)
    (exit 0))
  (let* ((file (if (pair? rest) (car rest) "/tmp/tuna-flood-50mb.txt"))
         (stamp (string-append "/tmp/tuna-flood-ended-" (number->string (random-integer 1000000000))))
         (command (if (equal? kind "seq") "seq 1 2000000" (begin (ensure-file! file) (string-append "cat " file)))))
    (with-terminals
     (lambda (folder)
       (start-kernel
        (lambda ()
          (set-memo-checking! #f)
          (set-plain-data-checking! #f)
          (start-editor-loop!)
          (on-editor (lambda () (call-command 'terminal)))
          (unless (screen-has? "*terminal*" "$ ") (error "No prompt"))
          (let ((latencies [])
                (peak (resident-mib))
                (start-memory (resident-mib))
                (running? #t)
                (statistics (##process-statistics))
                (start (now)))
            (spawn (lambda ()
                     (let lp ()
                       (when running?
                         (let (t0 (now))
                           (on-editor void)
                           (set! latencies (cons (- (now) t0) latencies)))
                         (thread-sleep! 0.01)
                         (lp)))))
            (spawn (lambda ()
                     (let lp ()
                       (when running?
                         (set! peak (max peak (resident-mib)))
                         (thread-sleep! 0.05)
                         (lp)))))
            (paste (string-append command "; date +%s.%N > " stamp "; printf '\\033]2;FLOOD-END\\007'; echo FLOOD-''DONE"))
            (press "RET")
            (let wait ((left 600.))
              (unless (or titled (<= left 0)) (thread-sleep! 0.01) (wait (- left 0.01))))
            (let drawn ((left 60.))
              (unless (or (string-contains (screen-text "*terminal*") "FLOOD-DONE") (<= left 0))
                (thread-sleep! 0.01) (drawn (- left 0.01))))
            (let* ((done (now))
                   (ended (with-catch (lambda (e) #f) (lambda () (string->number (call-with-input-file stamp read-line)))))
                   (sorted (list-sort < latencies)))
              (set! running? #f)
              (thread-sleep! 0.1)
              (with-catch void (lambda () (delete-file stamp)))
              (displayln "flood: " command)
              (displayln "  until shown (s): " (seconds-text (- done start)))
              (displayln "  program ran (s): " (if ended (seconds-text (- ended start)) "?"))
              (displayln "  backlog, program end to parsed (ms): "
                         (if (and ended titled) (milliseconds (- titled ended)) "?"))
              (displayln "  parsed to drawn (ms): " (if titled (milliseconds (- done titled)) "?"))
              (displayln "  editor answer (ms): median " (milliseconds (percentile sorted 0.5))
                         ", p99 " (milliseconds (percentile sorted 0.99))
                         ", worst " (milliseconds (if (null? sorted) 0. (last sorted)))
                         " (" (length sorted) " probes)")
              (let (after (##process-statistics))
                (displayln "  collections: " (- (f64vector-ref after 6) (f64vector-ref statistics 6))
                           ", taking (ms) " (milliseconds (- (f64vector-ref after 5) (f64vector-ref statistics 5)))
                           ", last live heap (MiB) " (round (/ (f64vector-ref after 17) 1048576.))))
              (displayln "  memory (MiB): before " (round start-memory) ", peak " (round peak)
                         ", after " (round (resident-mib))))))
        [flood-end-recorder]))))
  (exit 0))
