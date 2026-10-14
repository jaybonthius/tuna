;;; A session provider that keeps and saves nothing, for tests whose plugins
;;; register session slots (layouts require `session-service`) but
;;; that do not test the session.
(import :tuna/kernel
        (only-in :tuna/services/session session-service))
(export no-session-plugin)

(defstruct no-session ()
  final: #t)

(defmethod {add-session-slot! no-session}
  (lambda (self ctx slot priority) (void)))

(defmethod {save-session! no-session}
  (lambda (self) (void)))

(defmethod {restore-session! no-session}
  (lambda (self) (void)))

(defmethod {restart! no-session}
  (lambda (self owners apply rollback)
    (with-catch (lambda (e) (rollback) (raise e)) apply)))

(defmethod {state-directory no-session}
  (lambda (self) (error "This session keeps no state")))

(defplugin (no-session-plugin ctx)
  "Provides a session that keeps and saves nothing."
  provides: [session-service]
  (context-provide! ctx session-service (make-no-session)))
