# brussels.wtf brand kit

The selected identity is `05-compact-hand-v2.png`: the corrected Brussels Vijfhoek contour, yellow fill, black outline, compact white pinched-fingers hand entering from left to right, and condensed lowercase wordmark. `logo-stacked-approved.png` is an unchanged copy of that approved source.

Open [index.html](index.html) for a visual inventory. These files are packaged for use; the application templates and existing favicon have not been changed.

## Files

| File | Use | Background / size |
| --- | --- | --- |
| `logo-stacked-approved.png` | Approved identity reference, stacked presentation | White, 1254 × 1254 |
| `logo-horizontal-light.png` | Header or footer on light surfaces | Transparent, 2172 × 724 |
| `logo-horizontal-dark.png` | Dark header or footer | Opaque charcoal, 2172 × 724 |
| `icon-light.png` | Standalone symbol on light surfaces | Transparent, 1254 × 1254 |
| `icon-dark.png` | Standalone symbol on dark surfaces | Opaque charcoal, white outer keyline, 1254 × 1254 |
| `web/favicon.ico` | Browser fallback icon | Transparent, 32 × 32 |
| `web/favicon-16.png`, `web/favicon-32.png`, `web/favicon-48.png` | Browser icon PNG exports | Transparent |
| `web/apple-touch-icon.png` | Mobile home-screen shortcut | Opaque charcoal, 180 × 180 |
| `web/app-icon-192.png`, `web/app-icon-512.png` | App/manifest icon assets | Opaque charcoal; regular icons, not maskable |
| `avatar-400.png` | Social account avatar | Opaque charcoal, 400 × 400 |
| `social-card-1200x630.png` | Default preview when a page link is shared | White, 1200 × 630 |
| `banner-1500x500.png` | Wide social/profile banner | Charcoal, 1500 × 500 |

The banner is a general 3:1 export. Check the chosen platform's current crop before uploading. Sharing artwork has no tagline, so the same files work in French, Dutch, and English. Individual story cards with localized titles can be added later.

## Colour and typography

Use `#FFCC00` yellow, `#111111` charcoal, and `#FFFFFF` white as the working interface palette. These are intended design tokens; the generated PNGs contain slight colour and edge variation and are not perfectly flat spot-colour artwork. Use charcoal text on yellow. Keep article body text neutral and readable.

The wordmark is supplied artwork, not a verified font selection. Do not recreate it by guessing a typeface. Continue using the application's existing UI type until a typography decision is made.

## Use

- Keep the original orientation, aspect ratio, hand gesture and contour. Do not rotate, stretch, replace with a regular pentagon, or mirror the hand.
- Leave clear space of at least one quarter of the symbol's width around a placed logo. Do not count transparent canvas as visible symbol width.
- Start with a visible symbol height of 32 CSS pixels in navigation. Use the icon alone if the full wordmark would become hard to read. The supplied horizontal canvases include padding, so check visible artwork rather than only image dimensions.
- Favicons intentionally omit the wordmark. At 16 pixels, fine finger lines merge; the yellow outline provides recognition. The 32-pixel export retains more hand detail.
- On dark surfaces, use the white-keyline version. The supplied dark files have opaque backgrounds; they are suitable as tiles/banners but will not blend seamlessly into every dark theme colour.
- Keep meaningful images accessible with `alt="brussels.wtf"`; use empty alt text for a decorative icon beside an already labelled brand link.

## Implementation handoff

Place the required exports in the app's public static directory, then reference favicon PNGs/ICO and the Apple touch icon from the root layout. A web manifest can reference the 192- and 512-pixel files when app installation is introduced. These files alone do not make the website an installable app.

Use the sharing card through Open Graph / social image metadata with an absolute public URL. Keep language-specific page titles separate from the generic brand image. Set explicit dimensions on header images to avoid layout shifts.

## Next assets, when needed

1. A true editable SVG master, traced and checked against the approved source. Derive future variants from that one master to eliminate generation drift. Do not wrap a PNG in SVG and call it vector artwork.
2. Transparent dark lockups and one-colour black/white variants derived from that master, useful for arbitrary backgrounds, print and stamps.
3. Print-ready PDF, bleed and colour conversion for a specific printer when ordering stickers or merchandise.
4. Localized article-card or newsletter templates when those publishing channels launch.

## Production and validation

Visual adaptations were made with the built-in image_gen tool; final prompts are in [PROMPTS.md](PROMPTS.md). Generated adaptations can contain small differences from the approved source, which remains the identity reference. Unusable transparency attempts were excluded from this kit.

`bash export.sh` uses FFmpeg for reproducible format and size exports from the included sources. All exported PNGs and the ICO were decoded and their dimensions checked. The light icon and horizontal logo were verified to carry real alpha transparency. The 16-/32-pixel favicon and 180-pixel touch icon were visually inspected. Browser integration has not been performed or tested.
