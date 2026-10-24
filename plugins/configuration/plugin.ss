#lang :tuna/prelude
;;; The configuration plugin: the reload-config command, which loads
;;; init.ss again as a trial, applies only what changed and shows the
;;; reload report in the echo area; and the show-config-report command,
;;; which shows the last start-up or reload report there again. Both go
;;; through the configuration service (tuna/configuration.ss), which
;;; Tuna's start-up code provides. Commands run as tasks, so the reload
;;; holds the baton. The plugin binds no key; init.ss can. `tuna reload`
;;; from a terminal does not need this plugin.
(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/configuration)
(export configuration)

;; TEXT without its final newline; the echo area needs none.
(def (echo-text (text : :string)) => :string
  (if (and (fx> (string-length text) 0)
           (char=? (string-ref text (fx1- (string-length text))) #\newline))
    (substring text 0 (fx1- (string-length text)))
    text))

;; One line for a start-up with problems. This plugin owns the report
;; command, so its summary can always name that command.
(def (startup-report-summary (report : configuration-report))
  => (Maybe :string)
  (let* ((entries (configuration-report-entries report))
         (statuses (filter (lambda ((status : :symbol)) (not (memq status '(on restarted))))
                           (map (lambda ((e : :pair)) (car e)) entries)))
         (parts (filter-map
                 (lambda ((status : :symbol))
                   (let (names (filter-map (lambda ((e : :pair))
                                             (and (eq? (car e) status)
                                                  (cadr e)))
                                           entries))
                     (and (pair? names)
                          (string-append (symbol->string status) ": " (string-join names ", ")))))
                 (filter (lambda (status) (memq status statuses))
                         '(failed skipped off deferred replaced))))
         (where (string-append ". The report is in " (configuration-report-log report)
                               "; show-config-report shows it.")))
    (cond
     ((configuration-report-problem report)
      (string-append "Tuna start-up: the configuration did not load" where))
     ((null? parts) #f)
     (else
      (string-append "Tuna start-up: " (string-join parts "; ") where)))))

(defplugin (configuration ctx)
  "The reload-config and show-config-report commands."
  requires: [commands-service configuration-service]
  optional: [messages-service]
  (context-add-hook! ctx configuration-report-ready-hook 'summary
                     (lambda ((report : configuration-report))
                       (let (summary (startup-report-summary report))
                         (when (and summary (service-provider messages-service))
                           (message summary)))))
  (defcommand (reload-config) "Load init.ss again and apply what changed; show the report."
    (message (echo-text (reload-configuration-report))))
  (defcommand (show-config-report) "Show the last start-up or reload report of init.ss."
    (message (echo-text (or (last-configuration-report)
                            "There is no configuration report yet.")))))
