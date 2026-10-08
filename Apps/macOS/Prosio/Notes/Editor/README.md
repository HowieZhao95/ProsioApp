# Daily notes editor

The native WKWebView loads the committed `NotesEditor` folder directly. No Node runtime, CDN or network access is required by the shipped editor. Swift passes text as structured JavaScript arguments and receives versioned document messages.

To regenerate the bundle, from this directory run `npm ci` and `npm run build` using a supported Node release (24 LTS recommended). Dependencies are pinned by package-lock.json. Commit the regenerated JS, CSS, HTML and license files together. Build.mjs generates complete licenses for the dependencies present in the esbuild input graph; it fails if a bundled package has no license file.

CommonMark/GFM headings, emphasis, lists, tasks, quotes, code, links and tables use Milkdown 7.22.2. Unsupported HTML, images, math and frontmatter fall back to source mode to preserve original text. Rendering alone never rewrites Markdown; editing the rich document serializes it as Markdown. File attachments are not supported.

`outline.js` adds a compact chapter rail when the note contains headings. Hover or keyboard focus opens a floating directory; clicking a title scrolls to that heading, and scrolling updates the active chapter. It uses ProseMirror nodes in rich mode and the existing Markdown AST with measured textarea line positions in source mode. Duplicate headings remain distinct and fenced code is excluded. The directory never writes IDs or other metadata into the note. It follows the editor theme, supports the 320 pt minimum window, and respects reduced motion. Empty documents and notes without headings have no rail.

For interaction regression checks, see `tools/notes-ui-validation/outline-check.mjs` and the validation README.
