#lang :tuna/prelude
;;; The reload-config command: load init.ss again as a trial and apply
;;; only what changed (tuna/boot.ss), then show the reload report in the
;;; echo area. Commands run as tasks, so the reload holds the baton. The
;;; plugin binds no key; init.ss can. `tuna reload` from a terminal does
;;; not need this plugin.
(import :tuna/kernel
        :tuna/services/keys
        :tuna/boot)
(export reload-config-plugin)

(defplugin reload-config-plugin
  "The reload-config command: load init.ss again and apply what changed."
  requires: [input-service]
  (defcommand (reload-config) "Load init.ss again and apply what changed; show the report."
    (let (text (reload-report-text (reload-configuration!)))
      ;; The report ends with a newline; the echo area needs none.
      (message (substring text 0 (fx1- (string-length text)))))))
