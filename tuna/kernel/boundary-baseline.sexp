;;; Known hits of ADR 12's forbidden kernel nouns, checked by boundary-test.ss.
;;;
;;; Each entry is (file term count reason), with a positive count. The check
;;; fails when a file has more hits of a term than its entries allow, and
;;; when its entries allow more hits than remain, so this list can only
;;; shrink. A (file, term) may have several entries; their counts add up.
;;; Merge review confirms that a change to this file only removes or lowers
;;; entries.
;;;
;;; Every reason is "permanent: ..." and says why a word cannot go: the
;;; kernel cleanup (agents/plans/kernel-cleanup.md) removed every other hit.

;; Permanent.
("tuna/kernel/entries.ss" "keys" 1 "permanent: Gerbil std procedure hash-keys")
("tuna/kernel/plugins.ss" "keys" 1 "permanent: Gerbil std procedure hash-keys")
("tuna/kernel/plugins.ss" "position" 1
 "permanent: Gambit's source-location accessor ##locat-start-position, which defplugin uses to record where a plugin is defined")
