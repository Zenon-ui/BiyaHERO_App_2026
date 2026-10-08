const path = require('path');

module.exports = {
    root: path.resolve(__dirname, 'System'),

    // Relative URLs in the built index.html. The default '/' emits absolute
    // /assets/... paths, which break under any sub-path host and are the one
    // place the app still assumed it lives at the origin root.
    base: './',

    build: {
        outDir: path.resolve(__dirname, 'dist'),
        emptyOutDir: true
    }
};