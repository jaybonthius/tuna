(import (hooks) (options) (tables) (timers) (plugins))
(import (tuna) (disk))

;; Loaded, not imported, so unloading one of them in a test stays an
;; unload, which the configuration's reading again would undo at once.
(load-module! '(files))
(load-module! '(python))
(load-module! '(text))
(import (console))
