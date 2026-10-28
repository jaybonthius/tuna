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
        terminal-exit-hook
        terminal-input-hook
        terminal-prompt-hook
        terminal-command-start-hook
        terminal-command-finish-hook
        terminal-notification-hook
        terminal-progress-hook
        terminal-program-status-hook
        terminal-program-status-clear-hook
        terminal-reset-hook
        terminal-unknown-sequence-hook)

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

(def terminal-input-hook
  (new-hook 'terminal-input
            doc: "Runs with a terminal whose user sent its program input: a key, a paste, a line."))

;;; Shell integration (OSC 133): what the shell says about its prompts and
;;; commands. Shells skip steps and redraw prompts, so each event stands
;;; on its own.

(def terminal-prompt-hook
  (new-hook 'terminal-prompt
            doc: "Runs with a terminal and the prompt's kind ('primary, 'continuation, 'secondary or 'right) when its shell starts drawing a prompt (OSC 133 A, N or P)."))

(def terminal-command-start-hook
  (new-hook 'terminal-command-start
            doc: "Runs with a terminal and the command line its shell is about to run, or #f when the shell did not say, as the command starts (OSC 133 C)."))

(def terminal-command-finish-hook
  (new-hook 'terminal-command-finish
            doc: "Runs with a terminal, the exit code of the command that finished (#f when the shell did not say) and the seconds since it started (#f without a start), when the command finishes (OSC 133 D)."))

;;; What programs ask of the terminal beyond the screen.

(def terminal-notification-hook
  (new-hook 'terminal-notification
            doc: "Runs with a terminal, a title (\"\" for OSC 9) and a body when its program asks for a desktop notification (OSC 9 or OSC 777)."))

(def terminal-progress-hook
  (new-hook 'terminal-progress
            doc: "Runs with a terminal, a state ('remove, 'set, 'error, 'indeterminate or 'pause) and a percentage or #f when its program reports progress (ConEmu's OSC 9;4); a full reset reports 'remove."))

(def terminal-program-status-hook
  (new-hook 'terminal-program-status
            doc: "Runs with a terminal and the record its program reported (OSC 7501, checked by libghostty), which replaces the record of that id: the id (a /-separated path, \"\" for the program itself), the state ('idle, 'working, 'done, 'blocked or 'error), the kind ('permission, 'question or 'auth, for 'blocked) or #f, the progress (0-100) or #f, and the app, title and message strings or #f; the program-status contract's program-status-report has the same fields."))

(def terminal-program-status-clear-hook
  (new-hook 'terminal-program-status-clear
            doc: "Runs with a terminal and a record id when its program clears that record and the records under it (OSC 7501 state=clear); \"\" clears every record, as a full reset does."))

(def terminal-reset-hook
  (new-hook 'terminal-reset
            doc: "Runs with a terminal whose program reset it fully (RIS, ESC c)."))

(def terminal-unknown-sequence-hook
  (new-hook 'terminal-unknown-sequence
            doc: "Runs with a terminal, the kind of a sequence its terminal does not know ('osc or 'apc), its OSC number or #f, its content (after ESC ] or ESC _), whether that was cut at terminal-unknown-sequence-max-bytes, and its terminator ('bel or 'st, #f for APC)."))
