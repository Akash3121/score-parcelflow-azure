package web

import "embed"

// Assets contains the browser application.
//
//go:embed index.html styles.css app.js
var Assets embed.FS
