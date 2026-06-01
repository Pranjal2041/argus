// Package web holds the embedded web-client assets so the broker ships as a
// single self-contained binary (important for no-root cluster deploys).
package web

import "embed"

//go:embed index.html app.js
var Assets embed.FS
