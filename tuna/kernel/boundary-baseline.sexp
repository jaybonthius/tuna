;;; Known hits of ADR 12's forbidden kernel nouns, checked by boundary-test.ss.
;;;
;;; Each entry is (file term count reason). The check fails when a file has
;;; more hits of a term than its entries allow, and when its entries allow
;;; more hits than remain, so this list can only shrink. A (file, term) may
;;; have several entries; their counts add up.
;;;
;;; Reasons: "step N" names the step of agents/plans/kernel-cleanup.md that
;;; removes the hits; "permanent: ..." says why a word cannot go;
;;; "unassigned: ..." marks hits no planned step removes yet.

;; Step 2: opaque input (key-event, the quit key, and its client fields).
("tuna/kernel/loop.ss" "key" 14 "step 2")
("tuna/kernel/loop.ss" "client" 4 "step 2")

;; Step 3: commands out (the command registry and its declarative forms).
("tuna/kernel/plugins.ss" "defcommand" 4 "step 3")
("tuna/kernel/plugins.ss" "define-command" 3 "step 3")
("tuna/kernel/plugins.ss" "command-ref" 2 "step 3")
("tuna/kernel/plugins.ss" "command-entry" 3 "step 3")
("tuna/kernel/plugins.ss" "keymap" 1 "step 3")

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
("tuna/kernel/slots.ss" "keys" 1 "step 6")
("tuna/kernel/state.ss" "session" 1 "step 6")

;; Step 8: failure reporting (hand-over! and report-failure! messages).
("tuna/kernel/plugins.ss" "text" 6 "step 8")

;; Permanent.
("tuna/kernel/plugins.ss" "position" 1
 "permanent: Gambit's source-location accessor ##locat-start-position, which defplugin uses to record where a plugin is defined")

;; Unassigned: no planned step removes these.
("tuna/kernel.ss" "keys" 1
 "unassigned: dictionary-sense key; the facade exports entry-table-keys, which the keys plugin uses")
("tuna/kernel/entries.ss" "key" 13
 "unassigned: dictionary-sense key; entry tables are keyed by slot name")
("tuna/kernel/entries.ss" "keys" 3
 "unassigned: dictionary-sense key; entry-table-keys and its use of hash-keys")
("tuna/kernel/plugins.ss" "key" 3
 "unassigned: dictionary-sense key; the key parameter of context-add-entry!")
("tuna/kernel/plugins.ss" "keys" 2
 "unassigned: dictionary-sense key; hash-keys and entry-table-keys in provided-service-names and reconcile-adapters!")
("tuna/kernel/plugins.ss" "text" 7
 "unassigned: the Messages seam names its message parameter text (message!, message)")
("tuna/kernel/loop.ss" "render" 6
 "unassigned: comments on the Display seam and redisplay scheduling say render")
("tuna/kernel/loop.ss" "screen" 1
 "unassigned: display-service doc says \"Shows the current screen to clients.\"")
("tuna/kernel/loop.ss" "clients" 1
 "unassigned: display-service doc says \"Shows the current screen to clients.\"")
("tuna/kernel/loop.ss" "client" 1
 "unassigned: the Display interface comment says \"for every client\"")
("tuna/kernel/loop.ss" "keyboard" 1
 "unassigned: the signal-quit comment cites Emacs's keyboard-quit")
