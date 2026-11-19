# layout

Arranges views and shows them: the layout is the buffer ` *layout*`, whose containers, of kinds that container plugins define, hold view atoms. Every client shows the same selected view, zoom and focused children; after each batch, layout sends each client its screen and the page's title.
