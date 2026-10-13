;;; The session plugin (startup tier; ADR 5): keeps the session slots
;;; plugins register, and saves them in $XDG_STATE_HOME/tuna/session.ss. It
;;; saves while the editor is idle, when anything changed, and when the
;;; program saves it on exit; the program restores it once the configured
;;; plugins are active. After that, a plugin turned on later (by a reload
;;; of init.ss) gets its slots' saved data once it is active, and a slot's
;;; data is kept in memory when its plugin turns off, so a new version of
;;; the plugin gets the latest state rather than what the file held.
;;;
;;; The file holds one datum, (tuna-session 1 (SLOT VERSION DATA) ...),
;;; written with `write`. It is read with `read` and validated as plain
;;; data, never evaluated. A file that fails is moved aside and reported,
;;; and Tuna starts without it. Data of slots no active plugin registers is
;;; kept, so turning a plugin off does not erase what it saved.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/lib/timers
        :tuna/services/session)
(export session-plugin
        session-state-directory)

;; The state directory; #f means $XDG_STATE_HOME/tuna, or
;; ~/.local/state/tuna when that is unset. Tests point it elsewhere.
(def session-state-directory (make-parameter #f))

(def save-interval 2.)                  ; seconds between idle saves

(def format-version 1)

(def (default-state-directory) => :string
  (let (xdg (getenv "XDG_STATE_HOME" ""))
    (path-expand "tuna"
                 ;; The XDG specification ignores relative paths.
                 (if (string-prefix? "/" xdg)
                   xdg
                   (path-expand ".local/state" (getenv "HOME" "/"))))))

(defclass session-store ((slots     : entry-table)  ; slot name -> session-slot entries
                         (directory : :string)
                         (entries   : :list)     ; (slot version data), as last read or written
                         (written   :? :t)       ; the datum the file holds, if known
                         (restored? : :boolean)  ; the program's restore has run
                         ;; Slots that hold their plugin's real state: restored,
                         ;; or effective when the restore ran. Only these are
                         ;; saved when they are removed.
                         (live      : :list))
  final: #t)

;; The effective slot of each name, in the order the names were first
;; registered.
(def (effective-slots (self : session-store)) => :list
  (let (table self.slots)
    (map cdr
         (list-sort (lambda ((a : :pair) (b : :pair)) (fx< (car a) (car b)))
                    (map (lambda (name)
                           (let (entries (entry-table-entries table name))
                             (cons (foldl (lambda ((e : entry) (oldest : :fixnum))
                                            (fxmin (entry-serial e) oldest))
                                          (entry-serial (car entries))
                                          entries)
                                   (entry-value (car entries)))))
                         (entry-table-names table))))))

(def (session-file (self : session-store)) => :string
  (path-expand "session.ss" self.directory))

;; Report TEXT on stderr, and as a message when a plugin shows messages;
;; without one, message would write it to stderr a second time.
(def (report! (text : :string)) => :void
  (let (port (current-error-port))
    (display text port)
    (newline port))
  (when (service-provider messages-service)
    (message text)))

;; DATUM's slot entries if it is a valid session, or else #f.
(def (session-entries (datum : :t)) => (Maybe :list)
  (and (plain-data? datum)
       (match datum
         (['tuna-session (? (cut eqv? <> format-version)) . entries]
          (and (list? entries)
               (andmap (lambda (entry)
                         (match entry
                           ([(? symbol?) (? fixnum?) _] #t)
                           (else #f)))
                       entries)
               entries))
         (else #f))))

;; The one datum in the file at PATH, or #f if it holds anything else or
;; cannot be read.
(def (read-datum (path : :string)) => :t
  (with-catch
   (lambda (e) #f)
   (lambda ()
     (let (port (open-input-file [path: path char-encoding: 'UTF-8]))
       (unwind-protect
         (let* ((datum (read port))
                (more (read port)))
           (and (eof-object? more) datum))
         (close-port port))))))

;; The slot entries of the session at PATH. A missing file is an empty
;; session; an invalid one is moved aside and reported.
(def (read-session (path : :string)) => :list
  (if (file-exists? path)
    (let (entries (session-entries (read-datum path)))
      (if entries
        entries
        (let (aside (string-append path ".corrupt-"
                                   (number->string (inexact->exact (floor (time->seconds (current-time)))))))
          (rename-file path aside)
          (report! (string-append "The session file could not be read; moved it to " aside))
          [])))
    []))

(def (session-datum (entries : :list)) => :pair
  (cons* 'tuna-session format-version entries))

;; SLOT's entry, or #f after reporting why its data cannot be saved.
(def (save-slot (slot : session-slot)) => (Maybe :list)
  (let (name (session-slot-name slot))
    (with-catch
     (lambda (e)
       (report! (string-append "Session slot " (symbol->string name) " failed to save: "
                               (exception-summary e)))
       #f)
     (lambda ()
       (let (data ((session-slot-save slot)))
         (unless (plain-data? data)
           (error "Session slot data is not plain data" name))
         [name (session-slot-version slot) data])))))

;; Save every slot. Entries of slots that are not registered, or failed to
;; save, are kept as they were. The file is rewritten only if it changes.
(def (save! (self : session-store)) => :void
  (let* ((saved (filter-map save-slot (effective-slots self)))
         (names (map car saved))
         (entries (append saved
                          (filter (lambda ((entry : :pair)) (not (memq (car entry) names)))
                                  self.entries)))
         (datum (session-datum entries)))
    (unless (equal? datum self.written)
      (create-directory* self.directory)
      (write-file-atomically!
       (session-file self)
       (lambda (port)
         (display ";; Tuna session: plain data, read with `read` and never evaluated.\n" port)
         (write datum port)
         (newline port)))
      (set! self.written datum))
    (set! self.entries entries)))

;; Give each registered slot its saved data, in slot order. One slot
;; failing does not stop the others.
(def (restore! (self : session-store)) => :void
  (for-each (cut restore-slot! self <>) (effective-slots self))
  (set! self.restored? #t))

;; Give SLOT the data saved for it, and count it as live.
(def (restore-slot! (self : session-store) (slot : session-slot)) => :void
  (let (name (symbol->string (session-slot-name slot)))
    (match (assq (session-slot-name slot) self.entries)
      ([_ version data]
       (if (eqv? version (session-slot-version slot))
         (with-catch
          (lambda (e)
            (report! (string-append "Session slot " name " failed to restore: "
                                    (exception-summary e))))
          (lambda () ((session-slot-restore slot) data)))
         (report! (string-append "Session slot " name " was saved as version "
                                 (number->string version) "; skipped it"))))
      (else (void))))
  (set! self.live (cons slot self.live)))

;; Once the program's restore has run: restore the effective slots of P,
;; which has just turned on, that are not live yet.
(def (restore-plugin-slots! (self : session-store) (p : plugin)) => :void
  (when self.restored?
    (for-each (lambda (name)
                (let (best (entry-table-ref self.slots name))
                  (when (and best
                             (eq? (entry-owner best) (plugin-name p))
                             (not (memq (entry-value best) self.live)))
                    (restore-slot! self (entry-value best)))))
              (entry-table-names self.slots))))

;; SLOT's plugin is turning off: if SLOT is live and the only slot of its
;; name (REGISTERED is its entry), keep its latest data in memory for whatever
;; registers the name next, such as a new version of the plugin, and for
;; the next save. A slot that never got its state (its plugin failed
;; while turning on) saves nothing, so it cannot overwrite saved data; nor
;; does one whose name another slot keeps, which holds its own state.
(def (keep-slot-data! (self : session-store) (slot : session-slot) (registered : entry)) => :void
  (when (memq slot self.live)
    (set! self.live (remq slot self.live))
    (when (equal? (entry-table-entries self.slots (session-slot-name slot)) [registered])
      (let (saved (save-slot slot))
        (when saved
          (set! self.entries
            (cons saved (filter (lambda ((entry : :pair)) (not (eq? (car entry) (car saved))))
                                self.entries))))))))

(implement Session session-store
  (add-session-slot! (lambda (self ctx slot priority)
                       (let (new (context-add-entry! ctx self.slots (session-slot-name slot) slot
                                                     priority: priority))
                         ;; Runs before the entry is removed: receipts run backwards.
                         (context-defer! ctx (lambda () (keep-slot-data! self slot new))))))
  (save-session! (lambda (self) (save! self)))
  (restore-session! (lambda (self) (restore! self)))
  (state-directory (lambda (self) self.directory)))

(defplugin (session-plugin ctx)
  "Saves the session to $XDG_STATE_HOME/tuna/session.ss while idle and on exit, and restores it."
  (let* ((directory (or (session-state-directory) (default-state-directory)))
         (entries (read-session (path-expand "session.ss" directory))))
    ;; What the file holds, as far as saving needs to know.
    (using (self (session-store slots: (new-entry-table) directory: directory entries: entries
                                written: (session-datum entries) restored?: #f live: [])
                 : session-store)
      (context-add-hook! ctx plugin-activated-hook 'session
                         (lambda ((p : plugin)) (restore-plugin-slots! self p)))
      (context-run-with-timer! ctx save-interval save-interval
                               (lambda () (unless (input-pending?) (save! self)))
                               name: 'save-session)
      (context-provide! ctx session-service (Session self)))))
