;;; Terminals (ADR 18): what other plugins see of the terminals the
;;; terminal plugin runs. A terminal shows one program on a pseudo-terminal,
;;; held by a helper process outside Tuna, in a buffer. The plugin acts on
;;; none of what the program says beyond the terminal itself; it runs these
;;; hooks, each with the terminal first, and other plugins answer them.
;;;
;;; This contract is vocabulary only: it exports no service.
prelude: :gerbil/core

(import :tuna/kernel
        (only-in :tuna/plugins/buffers/contract buffer))
(export terminal
        terminal?
        terminal-id
        terminal-buffer
        terminal-title
        terminal-directory
        terminal-exit-status
        terminal-title-hook
        terminal-directory-hook
        terminal-bell-hook
        terminal-exit-hook)

;; One terminal: ID names its helper; SHOWN, its buffer, shows it; TITLE is what its
;; program last called it (OSC 0 or 2), "" for nothing; DIRECTORY is the
;; folder its program last reported (OSC 7), or #f; EXIT-STATUS is the
;; program's exit code, or 128 plus the signal that ended it, once it has
;; ended, else #f. The terminal plugin extends this class and keeps its
;; fields current.
(defclass terminal ((id          : :string)
                    (shown       : buffer)          ; `terminal-buffer`
                    (title       : :string)
                    (directory   :? :string)
                    (exit-status :? :fixnum)))

(def (terminal-buffer (t : terminal)) => buffer
  (terminal-shown t))

(def terminal-title-hook
  (new-hook 'terminal-title
            doc: "Runs with a terminal and its new title after its program sets the title (OSC 0 or 2)."))

(def terminal-directory-hook
  (new-hook 'terminal-directory
            doc: "Runs with a terminal and the folder its program reported (OSC 7) when it changes."))

(def terminal-bell-hook
  (new-hook 'terminal-bell
            doc: "Runs with a terminal whose program rang the bell (BEL)."))

(def terminal-exit-hook
  (new-hook 'terminal-exit
            doc: "Runs with a terminal and its program's exit status once the program has ended."))
