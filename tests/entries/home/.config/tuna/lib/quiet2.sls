#!tuna
(import (target) (helper))
(remove-hook! target:greeted helper:shout)
(advice-remove! target:text helper:wrap)
(table-remove! target:names 'harpo)
