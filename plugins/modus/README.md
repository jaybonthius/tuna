# modus

The Modus themes' colours for Tuna, from Protesilaos Stavrou's modus-themes for Emacs: modus-operandi-tinted in light and modus-vivendi-tinted in dark, each device following its own setting. `modus.css` holds Modus's colours as `--modus-…` variables by Modus's names, then sets Tuna's semantic and face tokens from them. A user changes one colour by setting its variable in `user.css`: `:root { --modus-bg-main: light-dark(#ffffff, #000000); }`.
