# start

Starts Tuna: reads the command line's flags, then has the plugin manager, `plugins`, install and load what the configuration names. `tuna --install` installs the libraries Tuna's own plugins name and compiles every plugin.

`tuna --test PATH…` runs test files through `test-runner`, each in a child Tuna with a home of its own; a plugin folder stands for the `.ss` files in its `tests/`. `tuna.deps` names chez-test, which gives every test file `(test)`.
