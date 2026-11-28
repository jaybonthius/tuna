# layout

Arranges views and shows them: the layout is the buffer ` *layout*`, whose containers, of kinds that container plugins define, hold view atoms. Every client shows the same selected view, zoom and focused children; after each batch, layout sends each client its screen and the page's title. A container kind lets the mouse resize its parts through layout's drag, which follows the pointer on the page and hands the lengths reached to the kind.
