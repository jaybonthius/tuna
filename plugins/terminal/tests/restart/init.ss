(use-plugin terminal
  (config
    (options:set! terminal:shell '("bash" "--norc" "--noprofile"))
    (options:set! terminal:environment '(("PS1" . "$ ") ("HISTFILE" . #f)))))
