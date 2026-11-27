(import (tuna) (test) (buffers) (files))

(test "the configuration's setting of buffers:revert-function wins over the global value files sets when it loads, and stays across files' reload"
  (check (eq? files:not-modified (buffers:revert-function)))
  (unload-owner! (module-owner '(files)))
  (load-module! '(files))
  (check (eq? files:not-modified (buffers:revert-function))))
