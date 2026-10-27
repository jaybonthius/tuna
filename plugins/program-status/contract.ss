;;; Program status (OSC 7501, the Program Status Protocol): the records
;;; each terminal's program keeps about itself, as the program-status
;;; plugin holds them (after ghostel-status). Other plugins, such as
;;; notifications, follow them through this hook.
;;;
;;; This contract is vocabulary only: it exports no service.
prelude: :gerbil/core

(import :tuna/kernel)
(export program-status-change-hook)

(def program-status-change-hook
  (new-hook 'program-status-change
            doc: "Runs with a terminal, a record id (\"\" for the program itself) and the record before and after it changed, each a program-status-report (the terminal contract's) or #f (#f before, for a new record; after, for one removed), whose app is its own or that of the nearest record above it that has one (ghostel-program-status-functions)."))
