;;; Session slots: state a plugin keeps across restarts, registered through
;;; its context (ADR 2, ADR 5). A slot turns the plugin's state into plain
;;; data and back. The kernel only keeps the registry; the session service
;;; decides where and when slots are saved and restored.
prelude: :gerbil/core

(import ./entries
        ./state
        ./plugins)
(export (struct-out session-slot)
        context-add-session-slot!
        session-slots)

;; SAVE returns the plugin's state as plain data; RESTORE receives data that
;; SAVE returned for the same VERSION, possibly in an earlier run.
(defstruct session-slot ((name    : :symbol)
                         (version : :fixnum)
                         (save    : :procedure)    ; -> plain data
                         (restore : :procedure))   ; plain data -> void
  final: #t)

;; Register the slot NAME for CTX's plugin until it is deactivated. Several
;; plugins may register the same name (alternative providers of one
;; service); the highest PRIORITY is effective.
(def (context-add-session-slot! (ctx : context)
                                (name : :symbol)
                                version:  (version  : :fixnum)
                                save:     (save     : :procedure)
                                restore:  (restore  : :procedure)
                                priority: (priority : :fixnum := 0))
  => :void
  (context-add-entry! ctx (kernel-slots (the-kernel)) name
                      (make-session-slot name version save restore)
                      priority: priority)
  (void))

;; The effective slot of each name, in the order the names were first
;; registered, so a slot restores after the slots registered before it.
(def (session-slots) => :list
  (let (table (kernel-slots (the-kernel)))
    (map cdr
         (list-sort (lambda ((a : :pair) (b : :pair)) (fx< (car a) (car b)))
                    (map (lambda (name)
                           (let (entries (entry-table-entries table name))
                             (cons (foldl (lambda ((e : entry) (oldest : :fixnum))
                                            (fxmin (entry-serial e) oldest))
                                          (entry-serial (car entries))
                                          entries)
                                   (entry-value (car entries)))))
                         (entry-table-keys table))))))
