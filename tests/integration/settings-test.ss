(import :std/test
        :tuna/kernel
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/lib/memo
        "../../tuna/tests/support/kernel"
        "../../tuna/tests/support/redraws")
(export settings-test)

(defsetting fill-column 70 "Where filling breaks lines.")

(defplugin (sets-wide ctx)
  "Sets fill-column globally to 100."
  requires: [settings-service]
  (context-set-setting! ctx fill-column 100))

(defplugin (sets-narrow ctx)
  "Sets fill-column globally to 40."
  requires: [settings-service]
  (context-set-setting! ctx fill-column 40))

(defplugin (scope-of-sixty ctx)
  "Adds a scope that resolves fill-column to 60."
  requires: [settings-service]
  (context-add-setting-scope! ctx 'sixty (lambda (s) (and (eq? s fill-column) (cons s 60))) priority: 10))

(def buffer-plugins
  [rope-text-store settings buffers])

(def settings-test
  (test-suite "tuna/plugins/settings"
    (test-case "a setting resolves through the dynamic layer, the buffer, global values, then its default"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (check (setting-value fill-column) => 70)
         (activate-plugin! sets-wide)
         (check (setting-value fill-column) => 100)
         (set-buffer-setting! (current-buffer) fill-column 80)
         (check (setting-value fill-column) => 80)
         (with-settings ((fill-column 20))
           (check (setting-value fill-column) => 20)
           (with-settings ((fill-column 10))
             (check (setting-value fill-column) => 10))
           (check (setting-value fill-column) => 20))
         (check (setting-value fill-column) => 80))))

    (test-case "sources: global values, scopes and a buffer's own values draw again what read the setting"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (read (lambda () (setting-value fill-column)))
           (check (drawn-again? read void) => #f)
           (check (drawn-again? read (lambda () (activate-plugin! sets-wide))) => #t)
           (check (drawn-again? read (lambda () (set-buffer-setting! (current-buffer) fill-column 80))) => #t)
           (check (drawn-again? read (lambda () (activate-plugin! scope-of-sixty))) => #t)
           (check (drawn-again? read (lambda () (deactivate-plugin! scope-of-sixty))) => #t)
           (check (drawn-again? read (lambda () (deactivate-plugin! sets-wide))) => #t)))))

    (test-case "drawing resolves settings without with-settings bindings"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (with-settings ((fill-column 20))
           (check (setting-value fill-column) => 20)
           (check (call-with-memo-pass (new-memo-cache) #f
                    (lambda () (memo 'p [] (lambda (i) (setting-value fill-column)))))
                  => 70)))))

    (test-case "global values are owner-tagged and revert in any order"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (activate-plugin! sets-wide order: 1)
         (activate-plugin! sets-narrow order: 2)
         (check (setting-value fill-column) => 40)
         (deactivate-plugin! sets-narrow)
         (check (setting-value fill-column) => 100)
         (activate-plugin! sets-narrow)
         (deactivate-plugin! sets-wide)
         (check (setting-value fill-column) => 40)
         (deactivate-plugin! sets-narrow)
         (check (setting-value fill-column) => 70))))

    (test-case "with-settings bindings belong to one thread; threads it starts inherit them"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (with-settings ((fill-column 20))
           (check (thread-join! (spawn (lambda () (setting-value fill-column)))) => 20))
         (let (other (spawn (lambda ()
                              (with-settings ((fill-column 5))
                                (thread-sleep! 0.05)
                                (setting-value fill-column)))))
           (check (setting-value fill-column) => 70)
           (check (thread-join! other) => 5)))))))
