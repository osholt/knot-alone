# TestFlight closed testing

The manual **TestFlight** workflow builds a signed App Store IPA, uploads it to
App Store Connect and, by default, assigns the processed build to Tide and
Seek's external tester group and submits the build for TestFlight beta review.
It is the Tide and Seek equivalent of the established Tail End Charlie path.

The iOS bundle identifier is `dev.osholt.tideandseek`, Apple team
`UY4624PH6X`. The workflow asks App Store Connect for the next free build number
unless one is supplied explicitly; it never guesses from GitHub run numbers.

## One-time Apple setup

1. Enable **Associated Domains** for `dev.osholt.tideandseek` in Apple Developer.
2. Regenerate the App Store provisioning profile. It must contain
   `applinks:tide-and-seek.tailendcharlie.app`; the workflow rejects a profile
   that does not.
3. In App Store Connect, create an external TestFlight group named
   **External Testers** (or use another exact name in the repository variable).
4. Complete **Test Information** for the app: Beta App Description, Feedback
   Email (`testing@tailendcharlie.app`), contact details and review notes. State
   that no account is required and that simulation can exercise the workflow.
5. Add testers by email to that external group. External builds require Apple's
   TestFlight beta review before those testers can install them.

## GitHub configuration

Add these repository secrets:

| Secret | Purpose |
| --- | --- |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 Apple Distribution `.p12` |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | `.p12` password |
| `APPLE_APPSTORE_PROFILE_BASE64` | Base64 App Store profile for this bundle ID and Associated Domain |
| `APPLE_CI_KEYCHAIN_PASSWORD` | Temporary runner-keychain password |
| `APPSTORE_CONNECT_API_KEY_ID` | App Store Connect upload API key ID |
| `APPSTORE_CONNECT_API_ISSUER_ID` | Upload key issuer ID |
| `APPSTORE_CONNECT_API_PRIVATE_KEY_BASE64` | Base64 upload `.p8` key |
| `APPSTORE_CONNECT_REVIEW_API_KEY_ID` | App Manager API key ID for external-group assignment/review |
| `APPSTORE_CONNECT_REVIEW_API_ISSUER_ID` | Review key issuer ID |
| `APPSTORE_CONNECT_REVIEW_API_PRIVATE_KEY_BASE64` | Base64 review `.p8` key |

Set these repository variables:

| Variable | Value |
| --- | --- |
| `TIDE_AND_SEEK_IOS_EXTERNAL_TESTER_GROUP` | Exact external group name, normally `External Testers` |
| `TIDE_AND_SEEK_TESTFLIGHT_INVITE_URL` | Optional Tide and Seek TestFlight invitation URL; the generic TestFlight page is used when absent |
| `TIDE_AND_SEEK_API_BASE_URL` | Optional HTTPS relay base for an internet-enabled tester build |
| `TIDE_AND_SEEK_FIREBASE_IOS_APP_ID` | Optional; leave unset until iOS push is configured |

The upload and review keys may be the same App Manager key, but both secret sets
remain explicit so upload-only access can later be separated from review access.
Never commit certificates, profiles, keys or tester addresses.

## Release and verify

Run **TestFlight** from `main` with `submit_external: true`. The workflow:

1. validates the certificate, bundle-specific profile and Associated Domain;
2. stamps the version, build, TestFlight track and build time into the app;
3. verifies the signed IPA and universal-link entitlement;
4. uploads idempotently; and
5. waits for processing, adds the build to the external group and submits beta
   review idempotently.

After Apple approval, install on a physical iPhone from the external invitation.
Confirm **Settings → About & build** shows the expected build and `TestFlight`,
then test both a planner link and a private voyage invitation. API success cannot
prove a tester's phone received the build, so that physical check remains a
release gate.
