#lang :tuna/prelude
;;; Notifications, shown in the echo area, as ghostel's default does when
;;; Emacs has no alert package (ghostel-default-notify): what a terminal's
;;; program asks for (OSC 9, OSC 777), and a program's status record
;;; entering a state worth knowing about (ghostel-status-notify), unless
;;; the buffer it belongs to is the one being looked at. Browser
;;; notifications, for a tab out of sight, are for later (the PWA work);
;;; they would come here.

(import :tuna/kernel
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/terminal/contract
        :tuna/plugins/program-status/contract)
(export notifications
        notify-program-status-states
        notification-text)

(defsetting notify-program-status-states '(blocked done error)
  "The states a program's status record entering notifies of (ghostel-status-notify-states), unless its buffer shows in the selected view.")

;; What the echo area says for a notification titled TITLE ("" for none,
;; when the program's buffer, named NAME, stands for it) with BODY.
(def (notification-text (title : :string) (body : :string) (name : :string)) => :string
  (string-append (if (string-empty? title) name title) ": " body))

(def (notify! (b : buffer) (title : :string) (body : :string)) => :void
  (message (notification-text title body (buffer-name b))))

;; Whether B is the buffer the selected view shows.
(def (looked-at? (b : buffer)) => :boolean
  (eq? (view-showing (selected-view)) b))

(defplugin (notifications ctx)
  "Shows what terminal programs ask to be told, and programs' status changes, in the echo area."
  requires: [settings-service buffers-service]
  ;; Its contract's vocabulary only: the report record and the change hook.
  optional: [program-status-service]
  (context-add-hook! ctx terminal-notification-hook 'notifications
                     (lambda ((t : terminal) (title : :string) (body : :string)) (notify! (terminal-buffer t) title body)))
  (context-add-hook! ctx program-status-change-hook 'notifications
                     (lambda ((b : buffer) (id : :string) (old :? program-status-report) (new :? program-status-report))
                       (when new
                         (let ((state (program-status-report-state new))
                               (kind (program-status-report-kind new)))
                           (when (and (memq state (buffer-local-value notify-program-status-states b))
                                      (not (and old (eq? state (program-status-report-state old))))
                                      (not (looked-at? b)))
                             (notify! b (or (program-status-report-title new) (program-status-report-app new) "")
                                      (or (program-status-report-message new)
                                          (if kind
                                            (string-append (symbol->string state) ": " (symbol->string kind))
                                            (symbol->string state))))))))))
