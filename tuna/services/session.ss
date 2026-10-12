;;; The session service (startup tier; ADR 5, ADR 12): where and when the
;;; session slots plugins register (`context-add-session-slot!`) are saved
;;; and restored. Saved state is plain data, written with `write` and read
;;; with `read`, never evaluated. Files are replaced atomically.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Session)
        session-service
        save-session
        restore-session
        state-directory
        plain-data?
        write-file-atomically!)

(interface Session
  ;; Save every slot's data now.
  (save-session!) => :void
  ;; Give each slot the data saved for it, in slot order. Call once, after
  ;; the plugins that own slots are active.
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
