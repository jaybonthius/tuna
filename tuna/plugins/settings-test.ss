(import :std/test
        :tuna/kernel
        :tuna/services/settings
        :tuna/services/buffers
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        "../test-support/kernel")
(export settings-test)

(defsetting fill-column 70 "Where filling breaks lines.")

(defplugin (sets-wide ctx)
  "Sets fill-column globally to 100."
  (context-set-setting! ctx fill-column 100))

(defplugin (sets-narrow ctx)
  "Sets fill-column globally to 40."
  (context-set-setting! ctx fill-column 40))

(def buffer-plugins
  [rope-text-store-plugin settings-plugin buffers-plugin])

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

    (test-case "global values are owner-tagged and revert in any order"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (activate-plugin! sets-wide)
         (activate-plugin! sets-narrow)
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
