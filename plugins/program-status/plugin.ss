#lang :tuna/prelude
;;; Program status (after ghostel-status): the records each terminal's
;;; program reports about itself (OSC 7501), kept with the protocol's
;;; lifetime rules, and shown in the terminal's status line, such as
;;; "[blocked: permission]". It follows only the terminal contract's
;;; hooks:
;;;
;;; - a report replaces its record; a clear removes a record and the
;;;   records under it, or every record (also at a full reset);
;;; - 'working and 'blocked records go when a new prompt starts or the
;;;   program ends; 'done and 'error ones stay until the user sends the
;;;   program input (program-status-acknowledge-on-input);
;;; - ConEmu progress (OSC 9;4) stands for the program's own record
;;;   until the program uses OSC 7501, and again after a full reset;
;;; - at most 256 records a terminal, the least recently changed going.
;;;
;;; Each change runs program-status-change-hook (the contract), as each
;;; runs ghostel-program-status-functions.

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        (only-in :tuna/plugins/renderer/contract renderer-service context-add-status-line-part!)
        (only-in :tuna/lib/memo source new-source record-read! source-changed!)
        :tuna/plugins/terminal/contract
        :tuna/plugins/program-status/contract)
(export program-status
        program-status-acknowledge-on-input
        program-status-labels
        program-status-show-app
        status-label)

(defsetting program-status-acknowledge-on-input #t
  "Whether sending a terminal's program input drops its 'done and 'error status records (ghostel-status-acknowledge-on-input).")
(defsetting program-status-labels '((working . "...") (blocked . "blocked") (done . "done") (error . "error"))
  "What a terminal's status line shows for its program's status, per state (ghostel-status-mode-line-labels): 'working with a percentage shows the percentage, 'blocked with a kind adds it; a state without an entry shows nothing.")
(defsetting program-status-show-app #t
  "Whether the status line names the program that reported its status (OSC 7501's app), as \"[claude-code: blocked]\". ghostel shows it in the tooltip instead, which Tuna's status line has none of.")

;; The records of one terminal, most recently changed first, each (ID .
;; REPORT); whether its program has used OSC 7501 since the last full
;; reset; and the source its status line reads.
(defclass terminal-records ((term     : terminal)
                            (records  : :list)
                            (seen?    : :boolean)
                            (shown    : source))
  final: #t)

(def max-records 256)

;; The app of the nearest record above record ID that has one, or #f.
(def (inherited-app (records : :list) (id : :string)) => (Maybe :string)
  (and (not (string-empty? id))
       (let* ((slash (string-rindex id #\/))
              (parent (if slash (substring id 0 slash) ""))
              (entry (assoc parent records)))
         (or (and entry (program-status-report-app (cdr entry)))
             (inherited-app records parent)))))

(def (change! (r : terminal-records) (id : :string) (old :? program-status-report) (new :? program-status-report))
  => :void
  (source-changed! r.shown)
  (run-hook program-status-change-hook r.term id old new))

;; Replace record ID with REPORT, its app inherited when it has none.
(def (set-record! (r : terminal-records) (id : :string) (report : program-status-report)) => :void
  (let* ((old (assoc id r.records))
         (app (or (program-status-report-app report) (inherited-app r.records id)))
         (new (if (equal? app (program-status-report-app report))
                report
                (make-program-status-report id (program-status-report-state report) (program-status-report-kind report)
                                            (program-status-report-progress report) app
                                            (program-status-report-title report)
                                            (program-status-report-message report))))
         (kept (cons (cons id new) (filter (lambda ((e : :pair)) (not (equal? (car e) id))) r.records))))
    (if (fx> (length kept) max-records)
      (let (evicted (last kept))
        (set! r.records (take kept max-records))
        (change! r (car evicted) (cdr evicted) #f))
      (set! r.records kept))
    (change! r id (and old (cdr old)) new)))

;; Remove the records PRED? takes (ID . REPORT).
(def (remove-records! (r : terminal-records) (pred? : :procedure)) => :void
  (let (removed (filter pred? r.records))
    (unless (null? removed)
      (set! r.records (filter (lambda (e) (not (pred? e))) r.records))
      (for-each (lambda ((e : :pair)) (change! r (car e) (cdr e) #f)) removed))))

;; Remove record ID and the records under it; "" removes them all.
(def (clear-records! (r : terminal-records) (id : :string)) => :void
  (let (prefix (string-append id "/"))
    (remove-records! r (lambda ((e : :pair))
                         (or (string-empty? id) (equal? (car e) id) (string-prefix? prefix (car e)))))))

(def (remove-in-states! (r : terminal-records) (states : :list)) => :void
  (remove-records! r (lambda ((e : :pair)) (memq (program-status-report-state (cdr e)) states))))

;; ConEmu progress (OSC 9;4) as the program's own record.
(def (progress-reported! (r : terminal-records) (state : :symbol) (percent :? :fixnum)) => :void
  (unless r.seen?
    (let (record (lambda ((state : :symbol) (percent :? :fixnum))
                   (set-record! r "" (make-program-status-report "" state #f percent #f #f #f))))
      (case state
        ((remove) (clear-records! r ""))
        ((set) (record 'working (or percent 0)))
        ((indeterminate) (record 'working #f))
        ((error) (record 'error #f))
        ((pause) (record 'blocked percent))
        (else (void))))))

;;; The status line

;; The records the status line shows: the 'blocked and 'error ones when
;; there are any, else the program's own (ghostel-status--shown).
(def (shown-records (records : :list)) => :list
  (let (pressing (filter (lambda ((e : :pair)) (memq (program-status-report-state (cdr e)) '(blocked error))) records))
    (cond
     ((pair? pressing) pressing)
     ((assoc "" records) => list)
     (else []))))

;; What the status line shows for RECORDS, newest first, with LABELS
;; (program-status-labels), naming the app when SHOW-APP?: "[LABEL]" with
;; " ×N" for several, or #f (ghostel-status--label).
(def (status-label (records : :list) (labels : :list) (show-app? : :boolean)) => (Maybe :string)
  (let (shown (shown-records records))
    (and (pair? shown)
         (let* ((report (cdar shown))
                (state (program-status-report-state report))
                (progress (program-status-report-progress report))
                (kind (program-status-report-kind report))
                (entry (assq state labels))
                (label (and (pair? entry) (string? (cdr entry)) (cdr entry)))
                (text (case state
                        ((working) (if progress (string-append (number->string progress) "%") label))
                        ((blocked) (if (and label kind) (string-append label ": " (symbol->string kind)) label))
                        (else label)))
                (app (and show-app? (program-status-report-app report))))
           (and text
                (string-append "[" (if app (string-append app ": ") "") text
                               (if (pair? (cdr shown)) (string-append " ×" (number->string (length shown))) "")
                               "]"))))))

(defplugin (program-status ctx)
  "Program status (OSC 7501) in a terminal's status line, kept as the protocol says."
  requires: [settings-service buffers-service]
  optional: [renderer-service]
  (let (by-buffer (make-hash-table-eq))      ; terminal's buffer -> terminal-records
    (def (records-of (t : terminal)) => terminal-records
      (or (hash-get by-buffer (terminal-buffer t))
          (let (r (terminal-records term: t records: [] seen?: #f shown: (new-source)))
            (hash-put! by-buffer (terminal-buffer t) r)
            r)))
    (context-add-hook! ctx terminal-program-status-hook 'program-status
                       (lambda ((t : terminal) (report : program-status-report))
                         (let (r (records-of t))
                           (set! (terminal-records-seen? r) #t)
                           (set-record! r (program-status-report-id report) report))))
    (context-add-hook! ctx terminal-program-status-clear-hook 'program-status
                       (lambda ((t : terminal) (id : :string))
                         (let (r (records-of t))
                           (set! (terminal-records-seen? r) #t)
                           (clear-records! r id))))
    (context-add-hook! ctx terminal-progress-hook 'program-status
                       (lambda ((t : terminal) (state : :symbol) (percent :? :fixnum))
                         (progress-reported! (records-of t) state percent)))
    ;; libghostty clears every record at a full reset itself.
    (context-add-hook! ctx terminal-reset-hook 'program-status
                       (lambda ((t : terminal)) (set! (terminal-records-seen? (records-of t)) #f)))
    (context-add-hook! ctx terminal-prompt-hook 'program-status
                       (lambda ((t : terminal) (kind : :symbol))
                         (remove-in-states! (records-of t) '(working blocked))))
    (context-add-hook! ctx terminal-exit-hook 'program-status
                       (lambda ((t : terminal) (status : :fixnum))
                         (remove-in-states! (records-of t) '(working blocked))))
    (context-add-hook! ctx terminal-input-hook 'program-status
                       (lambda ((t : terminal))
                         (when (buffer-local-value program-status-acknowledge-on-input (terminal-buffer t))
                           (remove-in-states! (records-of t) '(done error)))))
    (context-add-hook! ctx kill-buffer-hook 'program-status
                       (lambda ((b : buffer)) (hash-remove! by-buffer b)))
    (context-add-status-line-part! ctx 'terminal-status
                                   (lambda ((b : buffer))
                                     (let (r (hash-get by-buffer b))
                                       (and r
                                            (begin
                                              (record-read! (terminal-records-shown r))
                                              (status-label (terminal-records-records r)
                                                            (buffer-local-value program-status-labels b)
                                                            (and (buffer-local-value program-status-show-app b) #t)))))))))
