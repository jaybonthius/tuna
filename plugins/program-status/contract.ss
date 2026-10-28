;;; Program status (after ghostel-status): the records a program keeps
;;; about itself, such as working, blocked on a question, done or failed,
;;; by the buffer that shows it. A terminal's program reports them with
;;; OSC 7501 (the Program Status Protocol); an agent chat reports its
;;; agent's. Either calls report-program-status!; the plugin that provides
;;; the service keeps the records, shows them, and runs
;;; program-status-change-hook as each changes, which other plugins, such
;;; as notifications, follow.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        (only-in :tuna/plugins/buffers/contract buffer))
(export (struct-out program-status-report)
        (interface-out ProgramStatus)
        program-status-service
        report-program-status!
        program-status-change-hook)

;; One program status report (the Program Status Protocol, revision 0.4):
;; the record ID (a /-separated path, "" for the program itself) is now
;; in STATE ('idle, 'working, 'done, 'blocked or 'error), with KIND
;; ('permission, 'question or 'auth, for 'blocked), PROGRESS (0-100, for
;; 'working or 'blocked) and the APP, TITLE and MESSAGE the program sent,
;; or #f. The text holds no control characters.
(defstruct program-status-report ((id       : :string)
                                  (state    : :symbol)
                                  (kind     :? :symbol)
                                  (progress :? :fixnum)
                                  (app      :? :string)
                                  (title    :? :string)
                                  (message  :? :string))
  final: #t)

(interface ProgramStatus
  ;; Replace the record of B's program that REPORT names with REPORT.
  (report-program-status! (b : buffer) (report : program-status-report)) => :void)

(def program-status-service
  (new-service 'program-status is-ProgramStatus? tier: 'live
               doc: "Keeps the status records programs report, by the buffer that shows them."))

(def (report-program-status! (b : buffer) (report : program-status-report)) => :void
  (:- (with-service-provider (provider program-status-service ProgramStatus)
        (ProgramStatus-report-program-status! provider b report))
      :void))

(def program-status-change-hook
  (new-hook 'program-status-change
            doc: "Runs with a buffer, a record id (\"\" for the program itself) and the record before and after it changed, each a program-status-report or #f (#f before, for a new record; after, for one removed), whose app is its own or that of the nearest record above it that has one (ghostel-program-status-functions)."))
