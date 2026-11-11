#!tuna
(import (target) (helper))
(add-hook! target:greeted helper:shout)
(advice-add! target:text helper:wrap)
