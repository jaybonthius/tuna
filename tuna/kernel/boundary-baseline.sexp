;;; Known hits of ADR 12's forbidden kernel nouns, checked by boundary-test.ss.
;;;
;;; Each entry is (file term count reason), with a positive count. The check
;;; fails when a file has more hits of a term than its entries allow, and
;;; when its entries allow more hits than remain, so this list can only
;;; shrink. A (file, term) may have several entries; their counts add up.
;;; Merge review confirms that a change to this file only removes or lowers
;;; entries.
;;;
;;; Reasons: "step N" (N from 2 to 8) names the step of
;;; agents/plans/kernel-cleanup.md that removes the hits; "permanent: ..."
;;; says why a word cannot go.

;; Step 2: opaque input (key-event, the quit key, and its client fields).
("tuna/kernel/loop.ss" "key" 14 "step 2")
("tuna/kernel/loop.ss" "keydown" 1 "step 2")
("tuna/kernel/loop.ss" "client" 4 "step 2")
("tuna/kernel/loop.ss" "keyboard" 1 "step 2")   ; the signal-quit comment cites keyboard-quit

;; Step 3: commands out (the command registry and its declarative forms).
("tuna/kernel/plugins.ss" "defcommand" 4 "step 3")
("tuna/kernel/plugins.ss" "define-command" 7 "step 3")
("tuna/kernel/plugins.ss" "command-ref" 2 "step 3")
("tuna/kernel/plugins.ss" "command-entry" 3 "step 3")
("tuna/kernel/plugins.ss" "kernel-commands" 2 "step 3")
("tuna/kernel/plugins.ss" "keymap" 1 "step 3")
("tuna/kernel/state.ss" "kernel-commands" 1 "step 3")

;; Step 5: timers and jobs move to tuna/lib/; spans, rebase-spans, and text
;; change records move to the buffers contract.
("tuna/kernel.ss" "timers" 2 "step 5")
("tuna/kernel/timers.ss" "timer" 20 "step 5")
("tuna/kernel/timers.ss" "timers" 1 "step 5")
("tuna/kernel/jobs.ss" "key" 14 "step 5")
("tuna/kernel/jobs.ss" "span" 4 "step 5")
("tuna/kernel/jobs.ss" "spans" 8 "step 5")
("tuna/kernel/jobs.ss" "range" 1 "step 5")
("tuna/kernel/jobs.ss" "text" 1 "step 5")
("tuna/kernel/ids.ss" "span" 2 "step 5")
("tuna/kernel/ids.ss" "spans" 2 "step 5")
("tuna/kernel/ids.ss" "range" 1 "step 5")
("tuna/kernel/ids.ss" "text" 2 "step 5")
("tuna/kernel/ids.ss" "character" 1 "step 5")
("tuna/kernel/ids.ss" "positions" 1 "step 5")

;; Step 6: session slots move next to the session contract.
("tuna/kernel/slots.ss" "session" 9 "step 6")
("tuna/kernel/slots.ss" "save" 6 "step 6")
("tuna/kernel/slots.ss" "saved" 1 "step 6")
("tuna/kernel/slots.ss" "keys" 1 "step 6")
("tuna/kernel/state.ss" "session" 1 "step 6")

;; Step 7: dictionary-sense key/keys (entry tables, entry-table-keys, the
;; context-add-entry! parameter) are renamed to name/names.
("tuna/kernel.ss" "keys" 1 "step 7")
("tuna/kernel/entries.ss" "key" 13 "step 7")
("tuna/kernel/entries.ss" "keys" 2 "step 7")
("tuna/kernel/plugins.ss" "key" 3 "step 7")
("tuna/kernel/plugins.ss" "keys" 1 "step 7")

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
