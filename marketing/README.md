# InkPaper Marketing Assets

This folder keeps store screenshots and promotional images.

Rules:

- Store screenshots must come from real app rendering captured in the Android emulator or on a real Android device.
- Do not draw fake device frames, fake status bars, fake notches, fake signals, or fake app pages.
- Deliverable assets live under `marketing/real`.
- Drafts, local databases, emulator captures, and rejected generated assets should stay outside the repository.

Current pipeline:

1. Capture real emulator screenshots into `marketing/real/raw`.
2. Run `python3 marketing/generate_marketing_assets.py`.
3. Review the generated contact sheets in `marketing/real`.

Output folders:

- `marketing/real/google-play`: Google Play screenshots, 1080x1920, RGB PNG, plus the 512x512 store icon.
- `marketing/real/promo`: promotional images made from real app screenshots.
- `marketing/real/app-store`: legacy App Store screenshots from before the project became Android-only. Not shipped anywhere; kept for history only.
