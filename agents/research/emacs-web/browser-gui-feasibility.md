# Browser GUI Emacs: research and architecture decision

Research date: 2026-09-24. This is a research record, not authorization to change the implementation or adopt a runtime. No application code was changed for this research. The owner requires GUI Emacs in the browser, including their configuration and theme; prior instructions also require package-first rich HTML, Emacs-owned commands/state, Datastar CQRS/fat-morph examples, port 18086, no default Python dependency, and approval before a new production runtime or fork.

## Conclusion

`htmlize` helps export buffer decorations, but it is not the missing complete Emacs GUI frontend. A semantic HTML frontend still needs its own window-aware display renderer, source-position mapping, input translation, and update observation. Research did not find a stable public Elisp interface exposing all of Emacs's finished native redisplay output. That is a bounded finding, not a proof that an Elisp implementation is impossible.

There is a materially different, officially documented route: stock Emacs built with PGTK can use GTK 3's Broadway backend to display its native GUI in a browser. That avoids replacing Emacs's renderer. It is not the requested semantic HTML/Datastar renderer: it introduces a Broadway display service and native display protocol. It must be approved before becoming the project direction. Browser interaction, package compatibility, clipboard, IME, and session behavior still require validation; no Broadway demonstration was run here and no claim of perfect browser compatibility is made.

## What htmlize supplies—and what it does not

Source inspected: [Htmlize 1.59, commit fa644880699adea3770504f913e6dddbec90c076](https://github.com/emacsorphanage/htmlize/blob/fa644880699adea3770504f913e6dddbec90c076/htmlize.el).

- Public functions `htmlize-buffer`, `htmlize-region`, and `htmlize-region-for-paste` export existing buffer decorations. The [README](https://github.com/emacsorphanage/htmlize) explicitly warns that non-windowing Emacs limits output to terminal-supported colors.
- Its [face representation](https://github.com/emacsorphanage/htmlize/blob/fa644880699adea3770504f913e6dddbec90c076/htmlize.el#L980-L1016) supports foreground/background, size, bold/italic, and several text decorations. It does not preserve all GUI face attributes: font family, boxes, stipple, complete underline styling, and `:extend` are among the gaps. The parent independently checked this representation and the effective-color lookup in source.
- It handles selected overlay faces and strings, invisibility, string replacement, and images. Its [display conversion](https://github.com/emacsorphanage/htmlize/blob/fa644880699adea3770504f913e6dddbec90c076/htmlize.el#L492-L585) recognizes strings and images; other display forms fall back to original text. This is not equivalent to Emacs redisplay.
- It does not emit window topology, mode/header/tab lines, native visual rows, point/cursor geometry, mouse hit maps, or DOM-to-source position mappings. Window-specific overlays/remappings and exact overlay priority require additional work.
- Therefore “replace the demo renderer with htmlize” is not a completion plan. Do not add multiple renderer modes or claim unsupported properties work merely because HTML was produced. If the semantic route remains mandatory, evaluate htmlize behind a tested content-export seam; do not build the whole display contract around its internals or silently fall back to incorrect raw text.

## What stock Emacs exposes

The [GNU Elisp manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Basic-Windows.html) and [window geometry documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Coordinates-and-Windows.html) provide window topology, outer/body rectangles, buffer/point/start, and decoration heights. [Faces](https://www.gnu.org/software/emacs/manual/html_node/elisp/Face-Attributes.html), [overlay properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlay-Properties.html), [display properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Display-Property.html), and [child frames](https://www.gnu.org/software/emacs/manual/html_node/elisp/Child-Frames.html) expose substantial source semantics.

Those properties are inputs to native redisplay, not a completed display stream. Inspection of local upstream `src/dispextern.h` and `src/xdisp.c` found the richer native glyph matrices, row geometry, face IDs, margins/fringes, composition/bidi handling, and C display-backend callbacks. The glyph-dump functions found are debug-only diagnostics rather than a stable structured Elisp interface. Public position/pixel measurements remain useful, but do not establish general GUI parity on their own.

Inference: a semantic HTML implementation is a real frontend project. Theme and complete frame layout are feasible useful increments, but arbitrary-package equivalence, shaping, wrapping, popup frames, and hit testing need explicit fidelity gates. Unsupported features cannot count as passing acceptance for “fully functioning GUI Emacs.”

## Existing native-browser route

[GNU Emacs INSTALL](https://github.com/emacs-mirror/emacs/blob/master/INSTALL), section “Alternative window systems,” explicitly documents `--with-pgtk`, GTK **3**, and `GDK_BACKEND=broadway emacs ...`. Parent inspection of local upstream INSTALL lines 243–269 confirmed those statements. GTK 4 Broadway documentation is not the version-specific setup guide for this GTK 3 Emacs build.

The local machine already contains executable candidates:

- PGTK Emacs 30.2: `/nix/store/v536ngfhg79fin6sslz5f61f95v70qbx-emacs-pgtk-30.2/bin/emacs`. A batch query confirmed `--with-pgtk`; it also reports `--without-xwidgets`, which remains a compatibility limit for embedded native web widgets.
- GTK 3 Broadway: `/nix/store/mijaaxa13nv1h754xdic87f31z3mnbc6-gtk+3-3.24.52/bin/broadwayd`. Its help confirms explicit `--port` and `--address` options, so port 18086 and loopback binding are supported configuration options.
- These are observed local store paths, not a portable installation manifest. Availability does not establish working runtime compatibility or authorize production adoption.

The current PATH Emacs is a different build: `/nix/store/m8rvbsn5h1nx27wvk9ch9gxr8l2m8avx-emacs-nox-30.2`, configured without X and common image formats. The older geometry spikes used `/nix/store/a6jj06af2f82p1q6lhn9py4779qaph8z-emacs-gtk3-30.2/bin/emacs` with Xvfb. An X/GTK Emacs build is not interchangeable with the PGTK build needed for Broadway.

[Xpra's HTML5 client](https://github.com/Xpra-org/xpra-html5) is another native-application display route, but it adds a separate service/runtime and is not an Emacs semantic renderer. It is not the default recommendation here. [wasmacs](https://github.com/modeverv/wasmacs) documents terminal Emacs through xterm.js rather than native GUI frames; [emacs-ng](https://github.com/emacs-ng/emacs-ng) is a fork and does not establish a turnkey browser-native GUI solution.

## Local work and acceptance baseline

The present `emacs-web.el` proves browser input → Emacs native command loop → Elisp HTML → Datastar SSE. Its hard-coded CSS and single-buffer view are implementation shortcuts, not a requirement or proven production design. The Python files in `spikes/` remain disposable harnesses.

Retained geometry evidence is useful but bounded. `SPIKE-boundary-validation.log` records real clipping even with shared fonts. `SPIKE-gutter-fixture.el` adds a 5%-of-pane native margin and widens the browser container; its passing fixture tests do not prove general exact display fidelity. Do not turn that margin into an unexplained product requirement or claim universal browser/native metric equality.

Read-only inspection of `~/.config/emacs/post-init.el` identifies concrete acceptance cases: Modus mixed-font themes and theme switching, Doom Modeline, Meow and its Super-key toggle, Vertico/Vertico-buffer, Corfu completion, Treemacs with images and child-frame prompts, Org Superstar, ligatures, Magit/Transient, and Eat. These are configuration declarations, not proof every package is active or supported. The actual running configured GUI session must be the comparison oracle; do not replace it with `-Q` as the user-facing acceptance demonstration.

## Browser platform constraints apply to either route

The [Chrome Keyboard Lock documentation](https://developer.chrome.com/docs/capabilities/web-apis/keyboard-lock) says some browser/OS shortcuts are not normally delivered to web applications; keyboard lock only captures keys allowed by the OS, requires JavaScript-initiated fullscreen, and Chrome 130+ requires permission. A frontend must visibly handle shortcut conflicts and never promise capture of every system shortcut in every browser.

[MDN's beforeinput documentation](https://developer.mozilla.org/en-US/docs/Web/API/Element/beforeinput_event) notes that text composition and other edits may not emit cancelable `beforeinput` events and behavior varies by browser/OS. Keyboard-only event forwarding is not proof of IME/paste/mobile support. Clipboard and IME need real browser tests, regardless of rendering choice.

## Owner decision: keep semantic HTML

The two architectural goals are not interchangeable:

1. **Native GUI first:** evaluate stock PGTK Emacs through Broadway against the owner's configuration, retaining native rendering. This is the recommended route if the overriding objective is functioning GUI Emacs in the browser rather than semantic DOM content. It requires explicit approval to change the rich-HTML/Datastar rendering direction and adopt the display service. It does not require an Emacs fork or Python.
2. **Semantic HTML remains mandatory:** retain the package/Datastar direction and build the missing Emacs frontend. Htmlize is only a partial reuse candidate. Scope and completion must be expressed as an explicit GUI compatibility suite, with unresolved general redisplay gaps acknowledged rather than hidden behind a “perfect” claim. Any eventual native module or fork requires a separate owner decision.

The owner reviewed this trade-off and explicitly chose **Keep rich HTML/Datastar**. That settles the delivery direction: build the Emacs frontend, do not pivot to Broadway/Xpra. The native alternative above records the research and rejected recommendation; it is not the approved architecture. The resulting plan is [../PLAN.md](../PLAN.md). No runtime, dependency, fork, configuration, or application-code change has been made on the strength of subagent advice.
