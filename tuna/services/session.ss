;;; The session service (startup tier; ADR 5, ADR 12): the session slots
;;; plugins register (`context-add-session-slot!`), and where and when they
;;; are saved and restored. The provider keeps the slots. Saved state is
;;; plain data, written with `write` and read with `read`, never evaluated.
;;; Files are replaced atomically. A plugin that registers slots must
;;; require session-service and restart with it (not adapt), so its slots
;;; move to a new provider; a configuration that keeps no session provides
;;; one that saves nothing.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Session)
        (struct-out session-slot)
        session-service
        context-add-session-slot!
        save-session
        restore-session
        state-directory
        plain-data?
        write-file-atomically!)

;; State a plugin keeps across restarts (ADR 2, ADR 5). SAVE returns the
;; plugin's state as plain data; RESTORE receives data that SAVE returned
;; for the same VERSION, possibly in an earlier run.
(defstruct session-slot ((name    : :symbol)
                         (version : :fixnum)
                         (save    : :procedure)    ; -> plain data
                         (restore : :procedure))   ; plain data -> void
  final: #t)

(interface Session
  ;; Register SLOT for CTX's plugin until it is deactivated. Several plugins
  ;; may register the same name (alternative providers of one service); the
  ;; highest PRIORITY is effective. CTX's plugin must require session-service
  ;; and restart with it (not adapt), so its slots move to a new provider.
  (add-session-slot! (ctx : context) (slot : session-slot) (priority : :fixnum)) => :void
  ;; Save every slot's data now.
  (save-session!) => :void
  ;; Give the effective slot of each name the data saved for it, in the
  ;; order the names were first registered, so a slot restores after the
  ;; slots registered before it. Call once, after the plugins that own
  ;; slots are active.
  (restore-session!) => :void
  ;; The directory holding Tuna's state ($XDG_STATE_HOME/tuna).
  (state-directory) => :string)

(def session-service
  (new-service 'session is-Session? tier: 'startup
               doc: "Saves and restores session slots as plain data."))

(def (current-session) => Session
  (let (provider (service-provider session-service))
    (unless provider
      (error "No plugin keeps the session"))
    (Session provider)))

(def (context-add-session-slot! (ctx : context)
                                (name : :symbol)
                                version:  (version  : :fixnum)
                                save:     (save     : :procedure)
                                restore:  (restore  : :procedure)
                                priority: (priority : :fixnum := 0))
  => :void
  (Session-add-session-slot! (current-session) ctx
                             (make-session-slot name version save restore) priority))

(def (save-session) => :void
  (Session-save-session! (current-session)))

(def (restore-session) => :void
  (Session-restore-session! (current-session)))

(def (state-directory) => :string
  (Session-state-directory (current-session)))

;; Whether VALUE is plain data that `write` and `read` round-trip: lists,
;; vectors, strings, symbols, numbers, characters, and booleans, without
;; shared or cyclic structure. Keywords and Gambit's special objects
;; (#!eof, #!void) are not plain data.
(def (plain-data? (value : :t)) => :boolean
  (let (seen (make-hash-table-eq))
    (let check ((v value))
      (cond
       ((or (null? v) (boolean? v) (string? v) (char? v) (symbol? v)) #t)
       ((number? v) (and (real? v) (or (exact? v) (finite? v))))
       ((pair? v)
        (and (not (hash-get seen v))
             (begin (hash-put! seen v #t) #t)
             (check (car v))
             (check (cdr v))))
       ((vector? v)
        (and (not (hash-get seen v))
             (begin (hash-put! seen v #t) #t)
             (let lp ((i 0))
               (or (fx= i (vector-length v))
                   (and (check (vector-ref v i)) (lp (fx1+ i)))))))
       (else #f)))))

;; Replace the file at PATH with what WRITER, given a UTF-8 output port,
;; writes: into a temporary file beside it, then renamed over PATH, so
;; readers see the old file or the new one, never a partial one. If WRITER
;; fails, PATH is untouched and the temporary file is removed.
(def (write-file-atomically! (path : :string) (writer : :procedure)) => :void
  (let (temporary (string-append path ".tmp"))
    (with-catch
     (lambda (e)
       (when (file-exists? temporary)
         (delete-file temporary))
       (raise e))
     (lambda ()
       (let (port (open-output-file [path: temporary char-encoding: 'UTF-8
                                     create: 'maybe truncate: #t]))
         (unwind-protect
           (writer port)
           (close-port port)))
       (rename-file temporary path)))))
