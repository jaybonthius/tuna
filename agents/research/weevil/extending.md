# Extending Weevil

Weevil's public extension model is composable APIs from `weevil/config`:
commands, keymaps, hooks, options, and modes. Prefer composing those
APIs over replacing singleton providers.

## User config

Run with a local config while developing:

```sh
racket weevil/dynamic.rkt --config-dir ./config
```

Then edit:

```text
config/init.rkt
```

Basic shape:

```racket
#lang racket
(require weevil/config)
```

## Commands and keymaps

Define commands with `define-command`, then bind them in a keymap.
Standalone modifier keydowns (`Control`, `Alt`, `Meta`, `Shift`) are
ignored by the browser event bridge. Modified keys are normalized from
`KeyboardEvent.code`, not the printable `key`, so macOS Option/Alt
characters like `®` still bind as `M-r`. Internally, key names use
Emacs modifier names only: `C-` = Control, `M-` = Option/Alt,
`s-` = Super/Command/GUI, and `S-` = Shift. Examples: `C-k`, `M-x`,
`s-k`, `C-S-k`, and `C-SPC`.

```racket
(define-command (insert-fire-command)
  (insert! "🔥"))

(define-key! global-keymap "j" insert-fire-command)
(define-key! global-keymap "C-k" kill-line-command)
```

Remap an existing command without rebinding every key:

```racket
(define-command (my-newline-command)
  (insert! "\n\n"))

(remap-command! global-keymap newline-command my-newline-command)
```

## Hooks

Hooks are named callback lists. Normal hooks return ignored values.

```racket
(add-hook! pre-command-hook
           (lambda ()
             (displayln "before command")))

(add-hook! post-command-hook
           (lambda ()
             (displayln "after command")))
```

## Options

Options are registered values with contracts and docs.

```racket
(define-option silly-mode-enabled?
  #:default #f
  #:contract boolean?
  #:doc "Whether silly mode is enabled."
  #:group 'weevil)

(set-option! 'silly-mode-enabled? #t)
(option-ref 'silly-mode-enabled?)
```

## Unsafe page template override (escape hatch)

Page template replacement is advanced/unsafe. It is not exported by
`weevil/config`; require `weevil/unsafe/ui` explicitly.

```racket
(require weevil/config
         weevil/unsafe/ui)

(define (my-page #:subtitle [subtitle #f] . content)
  (apply default-page-template-provider
         #:subtitle (if subtitle
                        (string-append "🔥 " subtitle)
                        "🔥 Weevil")
         content))

(set-page-template-provider! my-page)
```

`define-extension-point` is a private core helper, not a public
extension API.
