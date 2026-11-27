(import (dired-test) (dired))

(dired-test:touch! "src/tuna/a.txt" "x\n")
(dired-test:folder! "notes")
(dired:visit "~/src/tuna")
(dired:visit "~/notes")
