#!tuna
(import (processes) (timers))

(define %self (current-owner))

;; The unload action is added after the attach, so it runs before the one
;; processes added, while the module is unloading and still attached.
(define (follow! process on-output)
  (call-as-owner %self
    (lambda ()
      (processes:attach! process (processes:output-end process) on-output)
      (on-unload
        (lambda ()
          (let ([end (processes:output-end process)])
            (let wait ()
              (when (<= (processes:output-end process) end)
                (timers:sleep 0.01)
                (wait))))
          (timers:sleep 0.05))))))
