;;; The test-only kernel facade. The kernel object is private to the
;;; kernel (ADR 12), so every test kernel comes from call-with-fresh-kernel.
;;; Production modules must not import or include anything in
;;; tuna/test-support/; tuna/kernel/boundary-test.ss checks this.
(import (only-in :tuna/kernel/plugins activate-plugin!)
        (only-in :tuna/kernel/state new-kernel current-kernel)
        :tuna/kernel)
(export activate-plugin!
        call-with-fresh-kernel
        wait-until)

;; Select a fresh kernel, activate PLUGINS in order, and call THUNK. Then,
;; even if activation or THUNK raises, stop the editor loop if it was
;; started and deactivate every plugin, so the kernel leaves no hook
;; callbacks behind. Returns THUNK's value.
(def (call-with-fresh-kernel (plugins : :list) (thunk : :procedure)) => :t
  (parameterize ((current-kernel (new-kernel)))
    (try
     (for-each activate-plugin! plugins)
     (thunk)
     (finally
      (stop-editor-loop!)
      (deactivate-all-plugins!)))))

;; Wait up to two seconds for (READY?) to become true.
(def (wait-until (ready? : :procedure)) => :boolean
  (let lp ((tries 200))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))
