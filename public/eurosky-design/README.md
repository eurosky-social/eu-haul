# eurosky-design (vendored, v0.1.0)

**A copy, and a temporary one.** These three CSS files are the plain-CSS build
of the Eurosky design system, taken unchanged from Publisher's copy
(`eurosky-publisher/vendor/eurosky-design/`), which was extracted from the
published design-system artifact because the `@eurosky/design` package does not
yet exist as a repository we can depend on.

Nothing here should be hand-edited: upstream generates every file from
`tokens/tokens.json`, and a local change would be silently lost when the real
package lands. Everything eu-haul adds on top lives in `public/eu-haul.css`.

They sit in `public/` because eu-haul has no asset pipeline; the layout links
them with a content hash for cache-busting (`ApplicationHelper#public_asset_path`).

## Replacing this with the real thing

When `@eurosky/design` exists, replace the three files with its `dist/`
equivalents. The file names match upstream's, so nothing else changes.

## Light only

`tokens.css` follows the operating system's dark mode unless `data-theme` is set.
eu-haul's design is light-only and the dark theme is an untested extrapolation,
so the layout pins `<html data-theme="light">`.
