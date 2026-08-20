# Tide and Seek Privacy Policy

Effective date: 20 August 2026

Tide and Seek is an offline-first sailing companion published by Oliver Holt.
This policy explains what the Android and iOS apps process, what can leave the
device, and the choices available to a sailor. Tide and Seek is currently a
private field-test product, not a certified navigation or distress system.

## The short version

- No account is required.
- The publisher does not use advertising, behavioural analytics, or sell user
  data.
- Voyage records, routes, preferences, contact details, and emergency details
  stay on the device unless the sailor deliberately shares or exports them.
- Opening online map, wind, weather, wave, or optional download features sends
  a request to the named provider. Weather requests include coordinates.
- Optional nearby crew sharing sends selected voyage data directly to accepted
  nearby devices over an encrypted connection.
- This Play release does not configure an internet crew relay or push
  notifications.

## Data kept on the device

Depending on the features used, the app may store:

- a display name, an app-generated installation/participant identifier, vessel
  appearance, preferences, and onboarding state;
- precise GNSS positions, route and track geometry, course and speed, voyage
  events, crew state, quick messages, MOB events, and voyage summaries;
- imported or created GPX routes and exported voyage files;
- optional phone number, emergency-contact details, and medical notes entered
  by the sailor;
- downloaded map data, forecasts, tide data, and an optional offline voice
  pack; and
- configuration for a boat-local AIS/NMEA receiver. Received AIS targets are
  kept ephemerally by default rather than uploaded as vessel history.

This information supports app functionality, safety features requested by the
sailor, and local voyage history. Android backup is disabled for the app.

The sailor can delete completed voyages individually, clear offline map data,
replace or clear editable profile fields, remove the optional voice pack, and
remove all remaining local app data by uninstalling the app or clearing its
storage in the operating system. Some short-lived received crew contact or
emergency details are purged at voyage end unless the recipient acted on them.

## Data that can leave the device

### Open-Meteo wind, weather, and wave forecasts

When the sailor opens the weather and wind view, Tide and Seek sends the current
position and a small surrounding chart area to the Open-Meteo forecast APIs over
HTTPS. Open-Meteo receives the requested coordinates and ordinary network
metadata such as the device IP address. Open-Meteo states that free-API server
logs used for maintenance, misuse prevention, and troubleshooting can contain
IP addresses and geographic coordinates and are deleted after 90 days.

Provider information: [Open-Meteo Terms and Privacy](https://open-meteo.com/en/terms).

### OpenFreeMap map content

Opening the map or downloading permitted offline map data requests styles and
tiles from OpenFreeMap over HTTPS. Requested tile addresses reveal the area of
the map being viewed, and the provider or its delivery network processes the
network request. OpenFreeMap states that it does not store IP addresses in its
regular logs, but may temporarily enable IP logging for a security incident for
up to 30 days, and may use Cloudflare to deliver content.

Provider information: [OpenFreeMap Privacy Policy](https://openfreemap.org/privacy/).

### Nearby crew sharing

If the sailor deliberately creates or joins a shared voyage and grants nearby
device permissions, Tide and Seek can exchange voyage data directly with
accepted nearby devices. Depending on the sailor's actions, this may include a
display name, an app-generated participant identifier, precise position, route,
track and voyage events, role and presence state, quick messages, and phone or
emergency/medical details the sailor explicitly chooses to share. A recipient's
device necessarily receives and may retain the shared data according to its
voyage lifecycle.

Nearby Connections are fully encrypted in transit. Google states that its
Nearby SDK can collect connection performance metrics and device information
(device model, country, build version, and app package name) for usage
diagnostics. Android users can control this under **Settings > Google > Usage &
diagnostics**.

Provider information: [Google Nearby Connections overview](https://developers.google.com/nearby/connections/overview).

### Optional downloads and user-directed hand-offs

- If the sailor chooses to install the offline natural voice pack, the app
  downloads a pinned, hash-verified file from a GitHub release. GitHub and its
  delivery network process that request under their own privacy terms.
- Exporting or sharing GPX or voyage information uses the operating-system share
  sheet. The destination chosen by the sailor handles the exported data under
  its own terms.
- Opening a website, dialler, or messaging app hands the selected information to
  that app only after the sailor chooses the action.
- The camera is used to scan voyage-invitation QR codes. Images are processed on
  the device and are not uploaded by Tide and Seek.

## Features not configured in this release

The current Google Play field-test build has no live internet crew relay,
network AIS provider, advertising SDK, publisher analytics, or configured push
notification service. Source code contains guarded adapters for some future
services, but their invalid or absent build configuration prevents those
services from operating in this release. This policy and the store declaration
will be updated before a distributed build enables a materially different data
flow.

## Retention and sharing choices

Local voyage data remains on the device until it is deleted through the app,
removed by the voyage lifecycle, cleared with the app's storage, or the app is
uninstalled. Forecast and tile caches remain until replaced or cleared. Nearby
crew sharing can be stopped by ending/leaving the voyage or disabling the
relevant permissions. Data already received by another crew device is controlled
by that recipient's copy of the app.

The publisher does not sell user data and does not use it for advertising. The
third-party providers above process only the requests required to deliver their
features or their documented service diagnostics and security functions.

## Legal basis and rights

For users in the United Kingdom or European Economic Area, optional provider
requests and crew transfers are made at the sailor's request to provide the
selected feature. Limited security and diagnostic processing is based on the
provider's or publisher's legitimate interest in operating a reliable and
secure service. System permissions and optional features can be refused or
disabled without creating an account.

Depending on local law, users may have rights to ask about, access, correct,
delete, restrict, or object to processing of their personal data, and to complain
to their data-protection authority. Most Tide and Seek data is held only on the
user's device and can be managed there. Requests about data handled by a named
provider should also be directed to that provider using the link above.

## Children

Tide and Seek is intended for adult sailors and is not directed to children
under 18. The publisher does not knowingly collect children's personal data.

## Security and limitations

Network provider requests use HTTPS and nearby device transfers are encrypted.
No method of storage or transmission is guaranteed to be completely secure.
Tide and Seek is a companion for private field testing; it is not a certified
chartplotter, an official chart source, an automatic distress transmitter, or a
substitute for seamanship, emergency equipment, or official information.

## Contact and changes

Privacy contact: [privacy@tailendcharlie.app](mailto:privacy@tailendcharlie.app).

Material changes will be dated and published at this same location. The Play
Data safety declaration will be updated when a distributed app version changes
the data practices described here.
