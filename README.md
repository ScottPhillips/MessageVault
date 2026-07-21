# MessageVault

MessageVault is a private, offline macOS 14+ exporter for the locally available Apple Messages library. It creates a searchable HTML archive alongside original attachments, a versioned JSON manifest, and SHA-256 checksums.

MessageVault checks the public GitHub Releases endpoint at most once per day and when **Check for Updates…** is selected. No message, contact, export, or usage data is transmitted.

## Build

1. Install Xcode 16 or newer and XcodeGen.
2. Run `xcodegen generate`.
3. Open `MessageVault.xcodeproj`, choose a Development Team, and run the MessageVault scheme.
4. Grant the built app Full Disk Access when prompted by its onboarding screen.

For local unsigned validation, use `xcodebuild -project MessageVault.xcodeproj -scheme MessageVault -configuration Debug CODE_SIGNING_ALLOWED=NO build`.

For a local test package, build Release and run `scripts/package-local.sh`. The packaging script preserves the Contacts entitlement in the ad-hoc Hardened Runtime signature; signing without that entitlement causes macOS to deny Contacts access before the app appears in Privacy settings.

## Distribution

The release script builds outside file-provider storage, signs with the installed Developer ID identity, submits with `notarytool`, staples the ticket, verifies the result, and creates the distribution zip:

1. Store credentials once with `xcrun notarytool store-credentials MessageVaultNotary`.
2. Run `scripts/release-notarized.sh`.

For Developer ID signing without submission, run `scripts/release-notarized.sh --skip-notarization`. The app is intentionally not sandboxed because it must read `~/Library/Messages`; it is not designed for Mac App Store distribution.

## Privacy and compatibility

- MessageVault performs no network requests and includes no analytics.
- It opens the Messages SQLite database read-only and never alters messages or attachments.
- Contacts access is optional and only resolves addresses to display names.
- Apple provides no public Messages export API. The local schema is undocumented and may change; unsupported schemas fail closed with a diagnostic.
- Only messages and attachment files currently available on the Mac can be exported. Cloud-only, expired, or deleted items are reported in `manifest.json`.

## Archive format

- `index.html` — searchable offline transcript
- `media/`, `documents/`, `audio/` — untouched original attachments
- `manifest.json` — versioned filter, participant, record, and missing-item metadata
- `checksums.csv` — SHA-256, byte size, category, timestamp, sender, and relative path
