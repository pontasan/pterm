# pterm

Native macOS terminal app bundle and distribution workflow.

## Build

Debug app bundle:

```bash
make debug
```

Release app bundle:

```bash
make build
```

This produces:

- `.build/pterm.app`

## Local Verification

Verify the bundle contains the expected executable and resources:

```bash
make verify-bundle
```

Create a distributable zip:

```bash
make package
```

This produces:

- `.build/pterm.zip`

## Signing

Sign the release app with a Developer ID Application certificate:

```bash
make sign IDENTITY='Developer ID Application: Your Name (TEAMID)'
```

Verify the signature and Gatekeeper assessment:

```bash
make verify-signature
```

## Notarization

Preferred workflow using a notarytool keychain profile:

```bash
make notarize \
  IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  NOTARY_PROFILE='your-notarytool-profile'
```

Alternative workflow using explicit credentials:

```bash
make notarize \
  IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  APPLE_ID='name@example.com' \
  TEAM_ID='TEAMID' \
  APPLE_APP_SPECIFIC_PASSWORD='app-specific-password'
```

After notarization, the app is stapled and verified in place.

## Distribution Readiness

For another person to launch the app normally on macOS without bypassing Gatekeeper, the expected sequence is:

1. `make build`
2. `make sign ...`
3. `make notarize ...`
4. distribute `.build/pterm.app` or `.build/pterm.zip`
