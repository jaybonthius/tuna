#!tuna
(import (target) (helper) (hooks) (tables))
(hooks:remove! target:greeted helper:shout)
(advice-remove! target:text helper:wrap)
(tables:remove! target:names 'harpo)
