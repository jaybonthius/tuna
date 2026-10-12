;;; Known hits of ADR 12's forbidden kernel nouns, checked by boundary-test.ss.
;;;
;;; Each entry is (file term count reason), with a positive count. The check
;;; fails when a file has more hits of a term than its entries allow, and
;;; when its entries allow more hits than remain, so this list can only
;;; shrink. A (file, term) may have several entries; their counts add up.
;;; Merge review confirms that a change to this file only removes or lowers
;;; entries.
;;;
;;; Reasons: "step 8" names the step of agents/plans/kernel-cleanup.md that
;;; removes the hits; "permanent: ..." says why a word cannot go.

;; Step 8: failure reporting and consumed-seam wording.
("tuna/kernel/plugins.ss" "text" 6 "step 8")   ; hand-over! and report-failure!
("tuna/kernel/plugins.ss" "text" 7 "step 8")   ; the Messages text parameter
("tuna/kernel/plugins.ss" "echo-area" 2 "step 8")
("tuna/kernel/state.ss" "echo-area" 1 "step 8")
("tuna/kernel/loop.ss" "render" 6 "step 8")    ; Display seam and redisplay comments
("tuna/kernel/loop.ss" "screen" 1 "step 8")
("tuna/kernel/loop.ss" "clients" 1 "step 8")
("tuna/kernel/loop.ss" "client" 1 "step 8")

;; Permanent.
("tuna/kernel/entries.ss" "keys" 1 "permanent: Gerbil std procedure hash-keys")
("tuna/kernel/plugins.ss" "keys" 1 "permanent: Gerbil std procedure hash-keys")
("tuna/kernel/plugins.ss" "position" 1
 "permanent: Gambit's source-location accessor ##locat-start-position, which defplugin uses to record where a plugin is defined")
