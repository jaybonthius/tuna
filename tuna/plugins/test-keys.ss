;;; Test fixtures for driving plugins with key events through the real
;;; editor loop; included by test files (not a module).

(import (only-in :tuna/services/keys make-key-event))

;; Activate PLUGINS in a fresh kernel, start the loop, run THUNK, and stop.
(def (call-with-editor plugins thunk)
  (parameterize ((current-kernel (new-kernel)))
    (try
     (for-each activate-plugin! plugins)
     (start-editor-loop!)
     (thunk)
     (finally
      (stop-editor-loop!)
      (deactivate-all-plugins!)))))

(def sequence 0)

(def browser-keys
  '(("RET" . "Enter") ("DEL" . "Backspace") ("SPC" . " ")
    ("<up>" . "ArrowUp") ("<down>" . "ArrowDown")
    ("<left>" . "ArrowLeft") ("<right>" . "ArrowRight")))

;; Send one key: "a", "RET", "C-f", "<up>".
(def (press key)
  (set! sequence (+ sequence 1))
  (let* ((ctrl? (string-prefix? "C-" key))
         (name (if ctrl? (substring key 2 (string-length key)) key))
         (browser-key (cond
                       ((assoc name browser-keys) => cdr)
                       (else name))))
    (submit-input! (make-key-event "test-client" sequence browser-key "" 0 #f #f #f ctrl? #f #f))))

(def (type! . keys)
  (for-each press keys))

;; Wait up to two seconds for (READY?) to become true.
(def (wait-until ready?)
  (let lp ((tries 200))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))
