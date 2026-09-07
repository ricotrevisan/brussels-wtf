# brussels.wtf brand kit

The selected identity is the corrected Vijfhoek contour with a compact left-to-right pinched-fingers hand. `logo-stacked-approved.png` preserves the original approved raster. Production variants now come from one editable [SVG master](master.svg), with no embedded raster or font dependencies.

Open [index.html](index.html) for the visual inventory.

| Files | Use |
| --- | --- |
| `master.svg` | Editable stacked master; mark and wordmark are named groups |
| `logo-stacked-light.svg`, `logo-stacked-dark.svg` | Stacked logo, transparent |
| `logo-horizontal-light.svg`, `logo-horizontal-dark.svg` | Header/footer logo, transparent |
| `icon-light.svg`, `icon-dark.svg` | Standalone icon, transparent |
| Matching `.png` files | Raster exports of those exact SVG paths |
| `web/favicon.svg`, `web/favicon.ico`, `web/favicon-{16,32,48}.png` | Browser icons; ICO includes 16, 32, 48 and 256 pixels |
| `web/apple-touch-icon.png` | Opaque 180 × 180 mobile shortcut |
| `web/app-icon-{192,512}.png` | Regular app icons, not maskable |
| `avatar-400.png` | Opaque square avatar with safe space for a circular crop |
| `social-card-1200x630.png` | Default link preview |
| `banner-1500x500.png` | Wide banner; check the destination's crop before uploading |

Both light and dark logo/icon variants have transparent backgrounds. Dark variants use white lettering and a white outer keyline. Mobile/portrait tiles and the wide banner use opaque charcoal backgrounds. The supplied sharing artwork is logo-only and works in French, Dutch and English.

## Usage

- Preserve aspect ratio, north-up map orientation and left-to-right hand pose. Do not independently redraw the hand or replace the outline with a generic pentagon.
- Keep space around the artwork of at least one quarter of the symbol width. Use the icon alone where a wordmark would be too small to read.
- The app displays the horizontal logo at 180 CSS pixels wide, reduced to 150 on narrow screens. Favicons omit the wordmark; at 16 pixels the silhouette carries most recognition.
- The palette is yellow `#FFCC00`, charcoal `#111111`, white `#FFFFFF`. Use charcoal text on yellow. Lettering is supplied as paths, not a font recommendation.
- Use an accessible `brussels.wtf` label on a brand home link. Decorative images inside that labelled link have empty alt text.

## App integration

Public headers use the SVG variants, selecting the appropriate version through the page's theme. Root metadata references the favicon, mobile shortcut, manifest, and a public absolute URL for the sharing card. Header links preserve the reader's locale. The manifest supplies browser shortcuts without introducing a service worker or claiming offline support.

## Regeneration

Run `bash output/brand/export.sh` from the repository root, or run `uv run scripts/export_brand.py` directly. CairoSVG renders the master-derived layouts; Pillow packages the multi-resolution ICO. The script also refreshes the ZIP. Edit `assets/brand/master.svg` to change the artwork, then regenerate.

`PROMPTS.md` and `sources/` document the earlier imagegen exploration. They are retained as history and are not sources for current exports. Native-vector tracing notes live in `assets/brand/README.md` in the repository.

For print, supply the SVG to the printer and obtain its specific bleed, colour and PDF requirements. Monochrome print variants and localized article-card templates can be derived from the master when needed.
