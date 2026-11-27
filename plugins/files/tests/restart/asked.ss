(import (tuna) (options) (commands) (buffers) (files) (files-test session))

(options:set! files:confirm-exit? #t)
(buffers:replace! (files:visit (files-test/session:home-path "d.txt")) 1 1 "edit")
(commands:run files:save-buffers-kill-tuna)
