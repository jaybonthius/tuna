(import (tuna) (test) (buffers) (files))

(test "an unload of files takes its value back; the configuration, which imports files, loads a new instance that sets it again"
  (let ([old (module-owner '(files))])
    (unload-owner! old)
    (check (not (owner-live? old)))
    (check (eq? files:revert-from-file (buffers:revert-function)))))
