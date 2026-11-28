(import (dired-test) (buffers) (dired))

(dired-test:folder! "killed")
(dired-test:touch! "src/tuna/a.txt" "x\n")
(dired-test:folder! "notes")
(define killed (dired:visit "~/killed"))
(dired:visit "~/src/tuna")
(dired:visit "~/notes")
(buffers:kill! killed)
