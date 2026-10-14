#lang :tuna/prelude
;;; The reload-config command: load init.ss again as a trial and apply
;;; only what changed, then show the reload report in the echo area; and
;;; the show-config-report command, which shows the last start-up or
;;; reload report there again. Both go through the configuration service
;;; (tuna/services/configuration.ss), which Tuna's start-up code
;;; provides. Commands run as tasks, so the reload holds the baton. The
;;; plugin binds no key; init.ss can. `tuna reload` from a terminal does
;;; not need this plugin.
(import :tuna/services/commands
        :tuna/kernel
        :tuna/services/configuration)
(export reload-config-plugin)

;; TEXT without its final newline; the echo area needs none.
(def (echo-text (text : :string)) => :string
  (if (and (fx> (string-length text) 0)
           (char=? (string-ref text (fx1- (string-length text))) #\newline))
    (substring text 0 (fx1- (string-length text)))
    text))

(defplugin reload-config-plugin
  "The reload-config and show-config-report commands."
  requires: [commands-service configuration-service]
  (defcommand (reload-config) "Load init.ss again and apply what changed; show the report."
    (message (echo-text (reload-configuration-report))))
  (defcommand (show-config-report) "Show the last start-up or reload report of init.ss."
    (message (echo-text (or (last-configuration-report)
                            "There is no configuration report yet.")))))
