;;; Settings resolution (startup tier): the dynamic layer, then plugin
;;; scopes, then owner-tagged global values, then the default (ADR 9).
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/settings)
(export settings-plugin)

(defclass setting-registry ((globals : entry-table)    ; setting -> value entries
                            (scopes  : entry-table))   ; 'chain -> lookup entries
  final: #t)

(def (scope-value (registry : setting-registry) (s : setting)) => (Maybe :pair)
  (let lp ((scopes (entry-table-entries registry.scopes 'chain)))
    (match scopes
      ([] #f)
      ([scope . more]
       (or ((: (entry-value scope) :procedure) s)
           (lp more))))))

(implement Settings setting-registry
  (resolve (lambda (self s dynamic)
             (cond
              ((assq s dynamic) => cdr)
              ((scope-value self s) => cdr)
              ((entry-table-ref self.globals s) => entry-value)
              (else (setting-default s)))))
  (add-global-value! (lambda (self ctx s value)
                       (context-add-entry! ctx self.globals s value)
                       (void)))
  (add-scope! (lambda (self ctx name lookup priority)
                (context-add-entry! ctx self.scopes 'chain lookup
                                    priority: priority doc: (symbol->string name))
                (void))))

(defplugin (settings-plugin ctx)
  "Resolves settings: with-settings bindings, then scopes such as the buffer, then global values."
  provides: [settings-service]
  (context-provide! ctx settings-service
                    (Settings (setting-registry globals: (new-entry-table)
                                                scopes: (new-entry-table)))))
