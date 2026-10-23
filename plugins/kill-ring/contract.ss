;;; The kill ring (Emacs's): the texts killed or copied, newest first, and
;;; a yank pointer into them, which yanking inserts from. Putting a text on
;;; it runs `kill-new-hook`, where a clipboard plugin can copy the text to
;;; the computer's clipboard (Emacs's `interprogram-cut-function`).
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out KillRing)
        kill-ring-service
        kill-new current-kill
        kill-new-hook)

(interface KillRing
  (kill-new (text : :string)) => :void
  (current-kill (n : :fixnum)) => :string)

(def kill-ring-service
  (new-service 'kill-ring is-KillRing? tier: 'live
               doc: "Keeps the texts killed or copied, for yanking."))

;; Runs with each text put on the kill ring, after it is there.
(def kill-new-hook
  (new-hook 'kill-new doc: "Runs with each text put on the kill ring."))

;; Put TEXT on the kill ring as its newest text, and point the yank
;; pointer at it (Emacs `kill-new`).
(def (kill-new (text : :string)) => :void
  (with-service-provider (provider kill-ring-service KillRing) (KillRing-kill-new provider text))
  (run-hook kill-new-hook text))

;; Move the yank pointer N texts older (newer for negative N), around the
;; ring, and return the text it points at (Emacs `current-kill`). Signals
;; when the ring is empty.
(def (current-kill (n : :fixnum)) => :string
  (:- (with-service-provider (provider kill-ring-service KillRing) (KillRing-current-kill provider n)) :string))
