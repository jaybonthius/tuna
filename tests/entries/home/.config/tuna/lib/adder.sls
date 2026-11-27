#!tuna
(import (target) (helper) (hooks))
(hooks:add! target:greeted helper:shout)
(advice-add! target:text helper:wrap)
