;;; Editing text: the region and the kill ring, which commands of other
;;; plugins use.
;;;
;;; The region (Emacs's region, with Transient Mark mode): the text of the
;;; selected view's focused text node between its point and its mark,
;;; which the buffers contract keeps on the view. While the region is
;;; active it is drawn, and commands that act on it use it; an edit, C-g
;;; and the commands that use it deactivate it. Commands turn the region
;;; off through this contract, not the view, so the plugin that provides
;;; it knows how the region was made: a region made by shifted motion keys
;;; or by the mouse (`set-temporary-region!`) ends at the next unshifted
;;; motion (Emacs's shift selection, and its `(only . …)` Transient Mark
;;; mode).
;;;
;;; The kill ring (Emacs's): the texts killed or copied, newest first, and
;;; a yank pointer into them, which yanking inserts from. Putting a text on
;;; it runs `kill-new-hook`, where a transport can copy the text to the
;;; computer's clipboard (Emacs's `interprogram-cut-function`), unless the
;;; text came from that clipboard.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/plugins/settings/contract)
(export (interface-out Editing)
        editing-service
        region-active? region-beginning region-end
        deactivate-mark! set-temporary-region!
        delete-selection
        kill-new current-kill
        kill-new-hook)

(interface Editing
  (region-active?) => :boolean
  (region-beginning) => :fixnum
  (region-end) => :fixnum
  (deactivate-mark!) => :void
  (set-temporary-region! (mark : :fixnum)) => :void
  (kill-new (text : :string)) => :void
  (current-kill (n : :fixnum)) => :string)

(def editing-service
  (new-service 'editing is-Editing? tier: 'live
               doc: "Keeps the region active or not, as Transient Mark mode does, and the texts killed or copied, for yanking."))

;; When on, typing, RET, DEL, C-d, yanking and pasting replace the active
;; region (Emacs `delete-selection-mode`). Off, as in Emacs.
(defsetting delete-selection #f
  "Whether typing, deleting, yanking and pasting replace the active region, as in other editors.")

;; Runs with each text put on the kill ring, after it is there, unless
;; the text came from the computer's clipboard.
(def kill-new-hook
  (new-hook 'kill-new doc: "Runs with each text put on the kill ring that did not come from the clipboard."))

;;; The region

;; Whether the selected view's region is active (Emacs `region-active-p`):
;; it has a mark, and the region is shown and used. It may be empty.
(def (region-active?) => :boolean
  (:- (with-service-provider (provider editing-service Editing) (Editing-region-active? provider)) :boolean))

;; The start of the region: the smaller of point and the mark, active or
;; not. Signals when there is no mark.
(def (region-beginning) => :fixnum
  (:- (with-service-provider (provider editing-service Editing) (Editing-region-beginning provider)) :fixnum))

;; The end of the region: the larger of point and the mark.
(def (region-end) => :fixnum
  (:- (with-service-provider (provider editing-service Editing) (Editing-region-end provider)) :fixnum))

;; Deactivate the selected view's region, keeping its mark (Emacs
;; `deactivate-mark`).
(def (deactivate-mark!) => :void
  (:- (with-service-provider (provider editing-service Editing) (Editing-deactivate-mark! provider)) :void))

;; Put the selected view's mark at MARK and activate its region until the
;; next unshifted motion command, or anything else that deactivates it,
;; as shift selection and the mouse do (Emacs's `(only . …)` Transient
;; Mark mode).
(def (set-temporary-region! (mark : :fixnum)) => :void
  (:- (with-service-provider (provider editing-service Editing) (Editing-set-temporary-region! provider mark)) :void))

;;; The kill ring

;; Put TEXT on the kill ring as its newest text, and point the yank
;; pointer at it (Emacs `kill-new`). FROM-CLIPBOARD? says TEXT was pasted
;; from the computer's clipboard, so kill-new-hook does not copy it back
;; there (Emacs binds `interprogram-cut-function` to nil for this).
(def (kill-new (text : :string) from-clipboard?: (from-clipboard? : :boolean := #f)) => :void
  (with-service-provider (provider editing-service Editing) (Editing-kill-new provider text))
  (unless from-clipboard?
    (run-hook kill-new-hook text)))

;; Move the yank pointer N texts older (newer for negative N), around the
;; ring, and return the text it points at (Emacs `current-kill`). Signals
;; when the ring is empty.
(def (current-kill (n : :fixnum)) => :string
  (:- (with-service-provider (provider editing-service Editing) (Editing-current-kill provider n)) :string))
