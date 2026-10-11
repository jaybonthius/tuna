# AGENTS.md

## Orientation

- Architecture decisions are in `docs/adr/`; read the relevant ones before designing or changing a subsystem. They override everything in `research/`.
- `docs/roadmap.md` names the current milestone.
- `research/README.md` indexes prior research from earlier attempts. Treat it as evidence, not as decisions, and re-verify version-sensitive Gerbil claims.
- The previous attempt is preserved at `/home/jay/Code/workbench-gerbil/tuna-old-2026-10` (including `stash@{0}`). Do not copy its customization macros, application-state framework, or buffer spec back in.

## How to work

- Build working vertical slices. Every milestone must run in the browser; specify interfaces and invariants, not the internals behind them.
- Keep plans to a page. Write an ADR only for a hard-to-reverse choice with real alternatives.
- Do not add review, oracle, or acceptance-report loops unless the owner asks. Validate with tests and by running the program.
- Prefer deleting an abstraction to defending it. Add a framework only when a second concrete user needs it.

## Gerbil

- Core modules use `prelude: :gerbil/core`, typed signatures, and `:std/interface` for replaceable services.
- Follow the editing protocol in `/home/jay/Code/workbench-gerbil/gerbil/AGENTS.md`: Gerbil MCP balance check before the first edit and after every edit, then syntax check, before compiling.
- Use the `gerbil-reference` skill before relying on an unfamiliar API, the `emacs-reference` skill for Emacs behavior, and the `datastar-guidance` skill for browser transport.
- Tests are co-located `*-test.ss` files exporting `*-test` suites.

## Commands

```sh
make deps          # install Gerbil package dependencies into .gerbil/
make               # build the browser asset and the Gerbil package
make test          # Gerbil tests and the keyboard-plugin test
make run           # build, then run .gerbil/bin/tuna
```

`gerbil build` needs at least one commit, because it records `git describe` in the package manifest. A Racket-era `tuna` binary may be on `PATH`; run this checkout's binary through `make run` or `gerbil env tuna`.

## HTML and CSS

Follow `docs/agents/html-css.md`. Stellar is not used; design values come from CSS custom properties.

## README scope

- Keep `README.md` brief: project introduction and essential install, build, and run instructions.
- Keep individual settings, API reference, implementation details, and behavioral caveats out of the README. Configuration examples belong in example config files.
- Update the README only when requested or when its essential setup instructions change. Routine feature changes do not require README additions or new documentation.
