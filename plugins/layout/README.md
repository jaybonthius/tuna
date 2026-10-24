# layout

The default layout: views arranged in a tree of containers, each `fit` (splitting its space) or `tabbed` (one child at a time), horizontal or vertical, with a movable frame, pins and frame marks. The minibuffer and echo area are ordinary views in it. Other plugins add container kinds with `context-define-container-kind!`; the layout contract lets another plugin replace this one.

## Acknowledgements

The recursive containers, tabs and acting on a parent container follow the i3 window manager; the planned scrolling strips follow the Niri compositor.
