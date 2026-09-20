# Silica

Silica is a local-first iPhone app that automatically records stays and movement, presents each day as a timeline and map, and exports the history as Markdown or to Notion.

The exported history can be stored in tools such as Obsidian or used as context for an AI agent. Silica does not include a built-in AI service and does not require an account for its core recording features.

Silica is available on the [App Store](https://apps.apple.com/app/id6795041286).

## Features

- Background stay and movement recording
- Daily timeline and map views
- Saved places and manual stay correction
- Manual and automatic Markdown export
- Optional Notion synchronization
- Local-first storage with no advertising tracking
- Monthly, annual, and lifetime Silica Pro plans powered by RevenueCat

## Repository structure

| Path | Purpose |
| --- | --- |
| `SilicaApp/` | SwiftUI iOS application |
| `Sources/SilicaCore/` | Testable stay, movement, export, and access policies |
| `Tests/SilicaCoreTests/` | Synthetic unit tests for the public package |
| `SilicaUITests/` | UI test and preview-data support |
| `Backend/` | Optional Cloudflare Worker used for Notion OAuth, synchronization, and feedback |
| `docs/` | Privacy policy, terms, and RevenueCat setup notes |

## Requirements

- Xcode 26 or a compatible Xcode version with Swift 6 support
- iOS 17 or later
- A physical iPhone for meaningful background-location testing
- An Apple development team and a unique bundle identifier for device builds

The Swift package containing the core logic can also be built and tested on macOS 14 or later.

## Run the iOS app

1. Clone this repository.
2. Open `Silica.xcodeproj` in Xcode.
3. Select the `Silica` scheme.
4. Choose your Apple development team and replace the bundle identifier with one you control.
5. Let Xcode resolve the RevenueCat Swift package dependency.
6. Build and run the app on an iPhone.
7. Complete onboarding and grant Always Location and Precise Location access. Motion & Fitness access is used to improve movement estimates.

The app can be explored without deploying the optional backend. Notion connection and in-app feedback use the hosted Silica API configured in `SilicaApp/Support/SilicaNotionIntegration.swift`.

## Run the core tests

```sh
swift test
```

The public suite covers export scheduling, Markdown rendering, subscription access,
movement fusion, stay validation, departure inference, and bootstrap behavior. All
fixtures use synthetic dates and coordinates.

## RevenueCat setup

The repository contains an Apple client SDK key because RevenueCat public SDK keys are designed to ship in client applications. It does not contain a RevenueCat secret API key or an App Store Connect private key.

To use your own RevenueCat project:

1. Create products for monthly, annual, and lifetime access.
2. Create an entitlement named `Silica Pro`.
3. Add the products to a current offering.
4. Replace `publicSDKKey` in `SilicaApp/Subscriptions/SubscriptionManager.swift`.
5. Update the product identifiers if your project uses different identifiers.

See `docs/revenuecat-setup.md` for the configuration used by Silica.

## Optional Notion backend

The source for the Cloudflare Worker is included in `Backend/` and its tests require Node.js 24. It keeps Notion OAuth credentials, encrypted installation secrets, encrypted Notion access tokens, and the optional Discord webhook on the server. Those secrets must never be embedded in the iOS app.

```sh
cd Backend
npm install
cp .dev.vars.example .dev.vars
npx wrangler d1 create silica-api
```

Then replace the placeholder D1 database ID and Notion settings in `Backend/wrangler.jsonc`, fill in `Backend/.dev.vars`, and run:

```sh
npm run db:local
npm test
npm run dev
```

For a self-hosted deployment, change the API base URL in `SilicaApp/Support/SilicaNotionIntegration.swift` and configure the matching Notion redirect URI. Apply all D1 migrations before deploying. This app and backend use a one-time, installation-bound OAuth completion step; older app versions cannot create new connections with this backend. See `Backend/README.md` for the flow and rollout requirements.

## Privacy and sample data

Location history is created at runtime and is not included in this repository. Screenshots, previews, and tests use synthetic example data. Do not commit exported location logs, local databases, signing material, `.dev.vars`, or device-specific deployment files.

## License

Silica is available under the MIT License. See `LICENSE`.

Third-party adaptations and their licenses are listed in `THIRD_PARTY_NOTICES.md`.
Third-party names, logos, map imagery, and screenshots remain subject to their respective owners' terms and are not relicensed under MIT.
