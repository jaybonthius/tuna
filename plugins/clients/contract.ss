;;; Clients: the places a person looks at the editor from, such as a
;;; browser tab (ADR 16). Every client mirrors the same editor; the few
;;; things kept per client (its keys in progress, its last command, what
;;; it measured) live in the plugins whose concepts they are, keyed by the
;;; client, never saved, and dropped when `client-gone-hook` runs.
;;;
;;; A transport makes a client for each place input comes from and puts it
;;; in the events it submits. The input plugin binds `current-client`
;;; inside each command's task, so a command, even one waiting at a
;;; prompt, sees the client whose input started it. Work no client started,
;;; such as a timer, sees #f.
;;;
;;; This contract is vocabulary only: it exports no service.
prelude: :gerbil/core

(import :tuna/kernel)
(export (struct-out client)
        current-client
        client-gone-hook)

;; One client. ID is the transport's name for it, unique among the
;; transport's clients; a transport that sees the same id again after the
;; client went away makes a new client.
(defstruct client ((id : :string))
  final: #t)

;; The client whose input started the running command, or #f.
(def current-client (make-parameter #f))

(def client-gone-hook
  (new-hook 'client-gone
            doc: "Runs on the editor loop with a client that went away; forget what was kept for it."))
