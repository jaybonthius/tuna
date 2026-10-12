;;; A session provider that keeps and saves nothing, for tests whose plugins
;;; register session slots (window managers require `session-service`) but
;;; that do not test the session; included by test files (not a module).

(import (only-in :tuna/services/session session-service))

(defstruct no-session ()
  final: #t)

(defmethod {add-session-slot! no-session}
  (lambda (self ctx slot priority) (void)))

(defmethod {session-slots no-session}
  (lambda (self) []))

(defmethod {save-session! no-session}
  (lambda (self) (void)))

(defmethod {restore-session! no-session}
  (lambda (self) (void)))

(defmethod {state-directory no-session}
  (lambda (self) (error "This session keeps no state")))

(defplugin (no-session-plugin ctx)
  "Provides a session that keeps and saves nothing."
  (context-provide! ctx session-service (make-no-session)))
