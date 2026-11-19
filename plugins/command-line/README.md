# command-line

Handles Tuna's command line once per process: each `--eval=EXPR` is evaluated at the REPL, so that `tuna --eval='(set-option! web:port 9450)'` sets an option over the configuration's setting; every other argument is a file to visit, the last shown at line `N` after `+N`; any other flag is reported.
