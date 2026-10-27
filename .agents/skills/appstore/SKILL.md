---
name: appstore
description: Prepare and validate a Mdown Mac App Store build. Not for GitHub Releases.
version: 1.1.0
allowed-tools:
  - Bash
  - Read
disable-model-invocation: true
---

# Mdown App Store Workflow

Use this skill only when the maintainer explicitly asks for App Store build or submission work.

## App Store vs GitHub Release

| Area | App Store | GitHub Release |
|---|---|---|
| Build intent | App Store distribution | Direct download and update feed |
| Entitlements | App Store entitlements | Developer ID entitlements |
| Sparkle | Not included | Included |
| Credentials | App Store Connect credentials | Developer ID and notarization credentials |

## Build And Validate

```bash
bash scripts/build-appstore.sh
xcrun altool --validate-app -f build/AppStore/Export/Mdown.app -t macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Use Xcode Organizer for upload when that is safer than CLI upload.

## Pre-Submission Checklist

- `MARKETING_VERSION` matches the intended release version.
- `CURRENT_PROJECT_VERSION` is incremented when required.
- App Store entitlements are used.
- The App Store configuration builds cleanly.
- Screenshots and metadata are ready in App Store Connect when needed.
- Submission copy ships with the build by default: derive Promotional Text and What's New (en and zh-Hans) from `.github/RELEASE_NOTES.md`, within App Store character limits (Promotional Text 170 chars), and hand them over with the build instead of waiting for the maintainer to ask at the submission form.

## Safety Rules

- Never upload to App Store Connect without explicit maintainer confirmation.
- Never commit App Store Connect API keys, certificates, passwords, or local credential paths.
- Validate before upload.
