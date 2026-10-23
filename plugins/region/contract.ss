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
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/plugins/settings/contract)
(export (interface-out Region)
        region-service
        region-active? region-beginning region-end
        deactivate-mark! set-temporary-region!
        delete-selection)

(interface Region
  (region-active?) => :boolean
  (region-beginning) => :fixnum
  (region-end) => :fixnum
  (deactivate-mark!) => :void
  (set-temporary-region! (mark : :fixnum)) => :void)

(def region-service
  (new-service 'region is-Region? tier: 'live
               doc: "Sets the mark and keeps the region active or not, as Transient Mark mode does."))

;; When on, typing, RET, DEL, C-d and yanking replace the active region
;; (Emacs `delete-selection-mode`). Off, as in Emacs.
(defsetting delete-selection #f
  "Whether typing, deleting and yanking replace the active region, as in other editors.")

;; Whether the selected view's region is active (Emacs `region-active-p`):
;; it has a mark, and the region is shown and used. It may be empty.
(def (region-active?) => :boolean
  (:- (with-service-provider (provider region-service Region) (Region-region-active? provider)) :boolean))

;; The start of the region: the smaller of point and the mark, active or
;; not. Signals when there is no mark.
(def (region-beginning) => :fixnum
  (:- (with-service-provider (provider region-service Region) (Region-region-beginning provider)) :fixnum))

;; The end of the region: the larger of point and the mark.
(def (region-end) => :fixnum
  (:- (with-service-provider (provider region-service Region) (Region-region-end provider)) :fixnum))

;; Deactivate the selected view's region, keeping its mark (Emacs
;; `deactivate-mark`).
(def (deactivate-mark!) => :void
  (:- (with-service-provider (provider region-service Region) (Region-deactivate-mark! provider)) :void))

;; Put the selected view's mark at MARK and activate its region until the
;; next unshifted motion command, or anything else that deactivates it,
;; as shift selection and the mouse do (Emacs's `(only . …)` Transient
;; Mark mode).
(def (set-temporary-region! (mark : :fixnum)) => :void
  (:- (with-service-provider (provider region-service Region) (Region-set-temporary-region! provider mark)) :void))
