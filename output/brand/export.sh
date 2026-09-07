#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

# Format and size exports only; visual adaptations were made with image_gen.
for size in 16 32 48; do
  ffmpeg -hide_banner -loglevel error -y -i icon-light.png -vf "scale=${size}:${size}:flags=lanczos" -frames:v 1 "web/favicon-${size}.png"
done
ffmpeg -hide_banner -loglevel error -y -i web/favicon-32.png -c:v bmp -frames:v 1 web/favicon.ico
for size in 192 512; do
  ffmpeg -hide_banner -loglevel error -y -i icon-dark.png -vf "scale=${size}:${size}:flags=lanczos" -frames:v 1 "web/app-icon-${size}.png"
done
ffmpeg -hide_banner -loglevel error -y -i icon-dark.png -vf 'scale=180:180:flags=lanczos' -frames:v 1 web/apple-touch-icon.png
ffmpeg -hide_banner -loglevel error -y -i icon-dark.png -vf 'scale=400:400:flags=lanczos' -frames:v 1 avatar-400.png
ffmpeg -hide_banner -loglevel error -y -i sources/social-card.png -vf 'scale=1200:630:force_original_aspect_ratio=decrease:flags=lanczos,pad=1200:630:(ow-iw)/2:(oh-ih)/2:white' -frames:v 1 social-card-1200x630.png
ffmpeg -hide_banner -loglevel error -y -i sources/banner.png -vf 'scale=1500:500:force_original_aspect_ratio=decrease:flags=lanczos,pad=1500:500:(ow-iw)/2:(oh-ih)/2:0x111111' -frames:v 1 banner-1500x500.png
