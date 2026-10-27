;;; Integration: checking a real plugin's declared services (tuna/plugin-use)
;;; takes well under the activation time limit, so the watchdog never stops
;;; a plugin for its check alone. The terminals plugin has the most private
;;; modules, each importing contracts again.
(import :std/test
        (only-in :tuna/plugin-use check-plugin-declarations!)
        (only-in :tuna/boot activation-time-limit)
        :tuna/plugins/terminal/plugin)
(export declared-use-test)

(def (seconds-to-check p)
  (let (start (time->seconds (current-time)))
    (check-plugin-declarations! p)
    (- (time->seconds (current-time)) start)))

(def declared-use-test
  (test-suite "integration: declared services are checked quickly"
    (test-case "the terminals plugin is checked in under a fifth of the activation time limit"
      (let (seconds (seconds-to-check terminals))
        (check (< seconds (/ (activation-time-limit) 5)) => #t)))))
