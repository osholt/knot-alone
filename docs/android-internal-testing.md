# Android closed testing

Tide and Seek follows the established Tail End Charlie and Balloon Crumbs
release path. The manual **Android closed testing** workflow builds a signed App
Bundle, uploads it to Google Play's `internal` track, and promotes the exact same
bundle to the private closed `alpha` track.

The Android package is permanently fixed as `dev.osholt.tideandseek`. The tester
opt-in page is:

`https://play.google.com/apps/testing/dev.osholt.tideandseek`

## One-time setup

1. Create the **Tide and Seek** Play Console app with package
   `dev.osholt.tideandseek` and enrol it in Play App Signing.
2. Complete the required Play app-content and testing declarations.
3. Create a dedicated Tide and Seek upload key. Do not reuse the TEC or Balloon
   Crumbs upload key.
4. Create or select a Google Cloud service account, enable the Google Play
   Android Developer API, and give that account app-scoped **Release apps to
   testing tracks** permission in Play Console.
5. Create the closed-testing track **Alpha** and attach the Google Group
   `tide-and-seek-testers@googlegroups.com`.
6. Keep managed publishing off unless a release is also going to be approved
   manually in Play Console.

## GitHub environment

The workflows use an Actions environment named `android-internal`, restricted
to `main`, with these secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded dedicated upload keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Upload keystore password |
| `ANDROID_KEY_ALIAS` | Upload-key alias |
| `ANDROID_KEY_PASSWORD` | Upload-key password |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Full service-account JSON key |

The closed tester group address is stored as the environment variable
`TIDE_AND_SEEK_ANDROID_TESTER_GROUP`. SMTP variables and credentials are
optional. The workflow defaults to `dry-run`, so its tester email is rendered
in the run summary but cannot be sent accidentally.

No keystore, password, service-account JSON, tester address list, or provider
credential belongs in the repository.

## Release

Run **Android closed testing** from GitHub Actions on `main` with:

- `build_number: 26` for the first release;
- `promote_to: alpha`; and
- `notification_mode: dry-run`.

If upload succeeds but promotion fails, run **Promote Android tester release**
with the existing version code. Run **Play track status** afterward and confirm
the version is on `alpha`.

Finally, open the opt-in page on a physical Android phone using a member of the
tester group. Install or update and confirm **Settings → About & build** reports
the expected version code and `Play closed testing (alpha)`.

Google Play API success cannot prove that a phone has received the build. That
physical check remains part of every first-time setup.

## Track safety

| Play Console surface | API track |
| --- | --- |
| Internal testing | `internal` |
| Closed testing — Alpha | `alpha` |
| Open testing | `beta` |
| Production | `production` |

The release workflow exposes only `alpha` or `none`; it cannot publish to open
testing or production.
