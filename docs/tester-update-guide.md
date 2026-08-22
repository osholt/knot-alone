# Tester update guide

## Android

Android testers use Google Play **closed testing**, track `alpha`.

1. Join `tide-and-seek-testers@googlegroups.com` with the Google account used
   on the test phone.
2. Open
   `https://play.google.com/apps/testing/dev.osholt.tideandseek` with that same
   account and accept the invitation.
3. Follow **Download it on Google Play**, then choose Install or Update.

Play may take several minutes to offer a new build. If necessary, refresh
**Google Play → Manage apps & device → Updates available**.

In Tide and Seek, open **Settings → About & build**. A closed-track build must
show the expected app version, build number, and
`Play closed testing (alpha)`. Copy those details into every report.

## iOS

Accept the emailed Tide and Seek external TestFlight invitation with the Apple
Account used on the test iPhone. Open TestFlight, pull to refresh, and choose
Install or Update. The first external build of a version appears only after
Apple completes beta review.

Confirm the version, build and `TestFlight` track in **Settings → About &
build** before reporting a problem. Send feedback to
`testing@tailendcharlie.app` with those build details.

Tester builds remain subject to the product and safety warnings in
[`PLAN.md`](../PLAN.md). They are not approved for navigation.
