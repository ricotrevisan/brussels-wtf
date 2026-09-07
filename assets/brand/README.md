# Brand source

`master.svg` is the editable source for production assets. Its `mark` group contains the Vijfhoek, outline and hand; its `wordmark` group contains the traced lettering, including transparent counters. The `contour` path supplies the dark-surface white keyline. Everything is a native SVG path: no embedded bitmap, remote resource, font dependency or script.

The master was traced from the user-approved `output/logo-concepts/05-compact-hand-v2.png`. The shape and hand posture are preserved while raster shading is flattened to yellow `#FFCC00`, charcoal `#111111` and white `#FFFFFF`. The approved raster remains unchanged as the comparison reference. This is a logo tracing, not a surveyed municipal boundary.

Initial tracing used VTracer 0.6.12 in spline mode. Pixels with all RGB channels below 135 supplied the black mask; R > 150, G > 100, B < 150 supplied yellow. Speckles below 20 pixels were excluded. The wordmark was traced separately in binary mode to preserve transparent counters. The initial trace was visually compared to the approved logo. Routine exports never retrace or regenerate the artwork.

Run `uv run scripts/export_brand.py` from the repository root. The script declares pinned CairoSVG and Pillow dependencies. It produces self-contained SVGs and PNGs under `priv/static/images/brand`, a multi-resolution `priv/static/favicon.ico`, and the updated downloadable `output/brand` kit. Dark logo/icon exports are genuinely transparent. All sizes, layouts and colour variants are derived from the same paths.

The primary UI accent uses the same yellow with charcoal text. Body typography and semantic status colours remain application concerns. The outlined wordmark does not require installing a guessed replacement font.

Small favicons have a larger symbol relative to their canvas than avatars. Mobile shortcuts use an opaque charcoal tile; manifest icons use `purpose: any`, not `maskable`. No service worker or offline behavior is introduced.

Review geometry changes in both themes and at 16, 32 and 180 pixels before exporting. For a specific print order, ask the printer for its PDF, bleed and colour-profile requirements; the SVG is an editable vector source, not a claim of printer-specific readiness.
