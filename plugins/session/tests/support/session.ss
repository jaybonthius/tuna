;;; A session provider that keeps and saves nothing, for tests whose plugins
;;; register session slots (layouts require `session-service`) but
;;; that do not test the session.
(import :tuna/kernel
        (only-in :tuna/plugins/session/contract session-service Session-service-view))
(export no-session)

(defstruct empty-session ()
  final: #t)

(defmethod {add-session-slot! empty-session}
  (lambda (self ctx slot priority) (void)))

(defmethod {save-session! empty-session}
  (lambda (self) (void)))

(defmethod {restore-session! empty-session}
  (lambda (self) (void)))

(defmethod {state-directory empty-session}
  (lambda (self) (error "This session keeps no state")))

(defplugin (no-session ctx)
  "Provides a session that keeps and saves nothing."
  provides: [session-service]
  (context-provide! ctx session-service (make-empty-session) view: Session-service-view))
