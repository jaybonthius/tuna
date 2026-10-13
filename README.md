# Tuna

Tuna is an extensible, browser-rendered computing environment in the spirit of Emacs, written in [Gerbil Scheme](https://cons.io).

## Install

With Gerbil on `PATH`:

```sh
./install.sh
```

## Build and run from source

Requires Gerbil v0.19 and esbuild on `PATH`.

```sh
make deps
make
make run
```

`make run` starts Tuna with the starter configuration, `starter/init.ss`. Otherwise Tuna reads your `~/.config/tuna/init.ss` (or `tuna --config PATH`); `tuna init` copies the starter there for you to edit. After editing it, `tuna reload` (or `C-c R` inside Tuna, with the starter) applies the changes without restarting.
