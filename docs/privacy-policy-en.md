# Silica Privacy Policy

Last updated: July 29, 2026  
Effective date: July 29, 2026

## 1. Overview

Taketo Fujimaki (“Provider,” “we,” “us,” or “our”) provides the Silica iOS application (“Silica” or the “App”). Silica is designed to process location history primarily on the user’s device and to use only the external services needed to provide features selected by the user.

The current version of Silica does not provide a Silica user account, display advertising, perform advertising tracking, use third-party analytics, or continuously store location history in a cloud database operated by us. If the user enables Notion integration, selected location logs are transmitted through our API to the user’s selected Notion destination. If the user submits an in-app support request, the request is transmitted through our API to an external support-management service.

This Privacy Policy explains the information processed by Silica, why it is processed, where it is stored, and how it can be deleted.

## 2. Information We Process

### 2.1 Location information

With the user’s permission, Silica uses Core Location to process:

- Arrival and departure times
- Latitude and longitude
- Horizontal accuracy
- Information about the source of a location update
- Current-location snapshots used during initial setup or similar operations
- Movement points used to supplement the timeline between stays

Silica uses this information to create a location history, display logs and maps, match visits with saved places, and generate exports.

Location information is stored in the App’s database on the user’s device. It is not sent to our API unless the user uses Notion export. Background visit recording may require “Always” location permission. Some features may not work if the user denies or limits location access.

### 2.2 Motion activity

Silica may read Core Motion activity information to estimate travel modes between stays, such as walking, running, cycling, or automotive travel, together with the confidence of the estimate.

The current version does not continuously store Core Motion activity records in the App’s location-history database. Results may be held temporarily on the device as needed to calculate and display travel modes.

### 2.3 Addresses and place names

Silica uses Apple’s Core Location and MapKit reverse-geocoding services to turn saved coordinates into readable addresses and place names.

Reverse geocoding is a network service. Coordinates and related request information may be transmitted to Apple to resolve an address or place name. Apple’s processing is governed by the [Apple Privacy Policy](https://www.apple.com/legal/privacy/) and the terms applicable to Apple’s services.

Resolved addresses and place names may be stored on the device for display, saved-place matching, and export.

### 2.4 Information stored on the device

Depending on how the user uses Silica, the App may store:

- Saved-place names, coordinates, matching radius, priority, and icon
- User corrections to addresses and place names
- Creation and update times for stays, movement points, and saved places
- Export date, destination path, export time, result, and error information
- A security-scoped bookmark used to access the folder selected by the user
- Language, appearance, Face ID lock, export destination, and other App settings

Silica does not access the user’s contacts, microphone, camera, or HealthKit data. If the user saves a Pro card image to Photos, the App uses permission to add that image but does not read existing photos from the photo library.

### 2.5 Markdown exports

If the user selects an export folder, Silica writes location-history Markdown files to that folder. An exported file may contain the date, time, place name, address, duration, and coordinates for unresolved places.

Silica does not send Markdown exports anywhere other than the folder selected by the user. If the folder is located in iCloud Drive or another file provider, synchronization, sharing, retention, and deletion are controlled by the user’s settings and that provider’s terms. The same applies if the folder is used by Obsidian or another application.

Deleting data inside Silica does not delete Markdown files already written to an external folder. The user must delete those files from the destination.

### 2.6 Notion integration

If the user connects Notion and selects a destination page or data source, Silica can send a location log containing dates, times, place names, addresses, durations, and coordinates for unresolved places to Notion, either manually or automatically.

The location-log body passes through our Cloudflare Worker only to fulfill the request. We do not store that body or the underlying location history in our Worker or D1 database. To operate the integration, we store a random installation identifier, an encrypted request-signing secret, an encrypted Notion access token, and workspace metadata.

Automatic export sends the previous day’s location log when the user has enabled that feature. Disconnecting Notion deletes the stored Notion connection and access token from our API, but it does not delete pages already created in Notion. The user must manage and delete exported pages in Notion.

Notion’s processing is governed by the [Notion Privacy Policy](https://www.notion.so/Privacy-Policy-3468d120cf614d4c9014c09f6adc9091) and the user’s agreement with Notion.

### 2.7 Face ID and device authentication

If the user enables Face ID lock, Silica asks iOS to authenticate the user before displaying the App. Silica does not receive or store facial images, biometric templates, or other biometric data. The App receives only the authentication result from iOS.

### 2.8 Purchases and subscriptions

Silica uses Apple’s App Store payment system and RevenueCat to offer and verify paid features.

Apple and RevenueCat may process purchase history, product identifiers, entitlement status, renewal or expiration dates, an anonymous App User ID, and technical information such as App version, OS version, and locale. Silica does not require a Silica account and does not intentionally send the user’s name or email address to RevenueCat.

Apple processes payment-card and payment-method details. We and Silica do not receive those details. RevenueCat’s processing is governed by its [Privacy Policy](https://www.revenuecat.com/privacy-policy/) and [Terms](https://www.revenuecat.com/terms).

### 2.9 Support requests

If the user submits an in-app support request, Silica processes the request category, subject, message, optional reply email address, App version, OS version, device type, language setting, Pro status, and a shortened portion of a random installation identifier.

The request passes through our Cloudflare Worker and is delivered to a private support-management environment used by the Provider. Silica does not automatically attach location history to a support request. Users should not include unnecessary location information, passwords, authentication credentials, or other sensitive information in the message.

We use support-request information to respond to the user, investigate bugs, prevent abuse, improve Silica, and maintain support records.

### 2.10 API authentication and security data

To protect the Notion and support APIs against impersonation, replay attacks, and abuse, we process:

- A random identifier issued for each App installation
- An encrypted API request-signing secret
- Request timestamps, one-time nonces, and signatures
- An irreversible hash derived from the source IP address for rate limiting
- Short-lived Notion OAuth state and Notion workspace metadata

The request-signing secret is stored in the iOS Keychain on the device and encrypted at rest on the server. Location-log bodies and support-message bodies are not stored in our D1 database.

## 3. Purposes of Processing

We process information only as needed to:

1. Provide location history, maps, logs, saved places, and travel-mode estimates
2. Resolve coordinates into addresses and place names
3. Export Markdown files to a folder selected by the user
4. Export location logs to a Notion destination selected by the user
5. Verify purchases and provide paid features
6. Respond to support requests, investigate bugs, prevent abuse, and maintain security
7. Comply with law and valid requests from courts or public authorities

We do not use location history for advertising, advertising measurement, sale to data brokers, or the sale of behavioral profiles.

## 4. Service Providers and International Processing

Silica uses:

- Apple: Core Location, Core Motion, MapKit, reverse geocoding, Photos add-only access, Face ID authentication, App Store, and StoreKit
- Cloudflare: API delivery, request security, rate limiting, and Notion/support relaying
- Notion: optional user-selected location-log destination
- RevenueCat: purchase and entitlement verification
- An external support-management service: receipt and management of in-app support requests

Their policies are available here:

- [Apple Privacy Policy](https://www.apple.com/legal/privacy/)
- [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/)
- [Notion Privacy Policy](https://www.notion.so/Privacy-Policy-3468d120cf614d4c9014c09f6adc9091)
- [RevenueCat Privacy Policy](https://www.revenuecat.com/privacy-policy/)
These providers may process or store information outside Japan or the user’s country of residence. Their processing is also governed by their policies and the agreements between the user, the Provider, and the relevant service provider.

We do not sell location history. Information is disclosed to a service provider only as needed to provide a feature selected by the user, protect the service, comply with law, or as otherwise described in this Policy.

## 5. Security

Location history, saved places, and export history are stored primarily in the App’s data container. Silica uses iOS file-protection capabilities, stores API credentials in the Keychain, signs API requests, and encrypts server-side Notion and request-signing secrets at rest. Face ID lock is available as an optional additional control.

No system can eliminate every risk. Users should protect the device passcode, Apple Account, iCloud account, Notion workspace, export folders, and any other connected service.

## 6. Retention and Deletion

### 6.1 On-device data

Location history, movement points, saved places, export history, and settings remain on the device until the user deletes them, resets App data, or removes the App, subject to iOS backups and restoration.

### 6.2 Exported files

Markdown files remain in the selected folder until the user deletes them. Deleting App data does not delete previously exported files.

### 6.3 Notion data

Disconnecting Notion deletes the Notion access token and workspace connection stored by our API. Pages already exported to Notion remain there until the user deletes them in Notion.

### 6.4 Support requests

Support requests are retained in a private support-management environment for as long as reasonably needed to respond, investigate issues, prevent abuse, and maintain support records. We delete information when it is no longer needed, unless retention is required by law or for security. Users may request deletion through the in-app support form.

### 6.5 API security data

OAuth state and request nonces expire after a short period and are deleted regularly. Rate-limit records are generally deleted within 24 hours. Installation identifiers and encrypted request-signing secrets are retained while needed to operate and protect the API. Subject to legal and security requirements, users may request their deletion through the in-app support form. Deletion will require the user to set up Notion and support API access again.

### 6.6 Purchase information

Apple and RevenueCat retain purchase and subscription information under their respective policies, agreements, and legal obligations. Deleting information required to verify purchases may prevent restoration of paid features.

## 7. User Choices and Requests

Users can:

- Change or revoke Location, Motion & Fitness, Photos, and Face ID permissions in iOS Settings
- Turn automatic export off in Silica
- Disconnect Notion in Silica
- Delete on-device data in Silica’s data-management screen
- Delete exported Markdown files from the selected folder
- Delete exported Notion pages in Notion
- Request access, correction, restriction, or deletion where provided by applicable law

To make a privacy request, use “Contact Support” in Silica’s Settings screen. We may request information reasonably necessary to verify the request. Do not send location history unless it is necessary to resolve the issue.

## 8. Children

Silica is not directed primarily to children. A parent or guardian should review location permissions, export destinations, and sharing settings before allowing a child to use the App.

## 9. Changes to This Policy

We may update this Policy to reflect changes in law, Silica, or third-party services. If a change is material, we will provide notice through the App, the public website, or another appropriate method. The updated Policy applies from the stated effective date.

## 10. Contact

For support, privacy requests, and requests to delete Notion-connection or support information, use “Contact Support” in Silica’s Settings screen.
