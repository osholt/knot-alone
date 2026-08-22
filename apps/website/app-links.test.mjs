import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const assetLinks = JSON.parse(await read("./.well-known/assetlinks.json"));
const appleAssociation = JSON.parse(
  await read("./.well-known/apple-app-site-association"),
);
const androidManifest = await read(
  "../mobile/android/app/src/main/AndroidManifest.xml",
);
const androidActivity = await read(
  "../mobile/android/app/src/main/kotlin/me/osholt/tide_and_seek/MainActivity.kt",
);
const iosDelegate = await read("../mobile/ios/Runner/AppDelegate.swift");
const iosEntitlements = await read("../mobile/ios/Runner/Release.entitlements");
const dartLinks = await read("../mobile/lib/domain/product_links.dart");

const HOST = "tide-and-seek.tailendcharlie.app";
const PLAY_FINGERPRINT =
  "80:06:4C:53:43:1C:5C:64:96:09:4B:0C:57:0A:FB:29:7D:F0:11:E5:CC:C3:6E:7C:76:C9:F5:57:9D:C4:26:17";

test("Android app links trust the Play signing certificate", () => {
  const target = assetLinks[0]?.target;
  assert.equal(target?.package_name, "dev.osholt.tideandseek");
  assert.deepEqual(target?.sha256_cert_fingerprints, [PLAY_FINGERPRINT]);
});

test("iOS universal links target plans and private voyage invitations", () => {
  const detail = appleAssociation.applinks?.details?.[0];
  assert.deepEqual(detail?.appIDs, ["UY4624PH6X.dev.osholt.tideandseek"]);
  assert.deepEqual(detail?.components?.[0]?.["/"], "/planner.html");
  assert.deepEqual(detail?.components?.[0]?.["?"]?.code, "?*");
  assert.deepEqual(detail?.components?.[1]?.["/"], "/join.html");
  assert.equal(detail?.components?.[1]?.["?"], undefined);
});

test("native and Dart link handlers use the same public host", () => {
  for (const source of [androidManifest, androidActivity, iosDelegate, iosEntitlements, dartLinks]) {
    assert.match(source, new RegExp(HOST.replaceAll(".", "\\.")));
    assert.doesNotMatch(source, /tideandseek\.invalid/);
  }
});

test("Android registers invitation and planner App Links side by side", () => {
  const filters = [
    ...androidManifest.matchAll(
      /<intent-filter android:autoVerify="true">([\s\S]*?)<\/intent-filter>/g,
    ),
  ].map((match) => match[1]);
  assert.equal(filters.some((filter) => filter.includes('android:path="/planner.html"')), true);
  assert.equal(filters.some((filter) => filter.includes('android:path="/join.html"')), true);
});

test("the invitation fallback cannot transmit its URL fragment", async () => {
  const page = await read("./join.html");
  const headers = await read("./_headers");
  assert.match(page, /name="referrer" content="no-referrer"/);
  assert.doesNotMatch(page, /<script\b/i);
  assert.match(page, /not sent to this website/i);
  for (const path of ["/join.html", "/join"]) {
    const start = headers.indexOf(`${path}\n`);
    assert.notEqual(start, -1, `${path} must have a header rule`);
    const next = headers.indexOf("\n/", start + path.length + 1);
    const rule = headers.slice(start, next === -1 ? undefined : next);
    assert.match(rule, /Referrer-Policy: no-referrer/);
    assert.match(rule, /connect-src 'none'/);
    assert.match(rule, /X-Robots-Tag: noindex/);
  }
});

test("public privacy, terms and tester destinations are linked", async () => {
  const [home, privacy, terms] = await Promise.all([
    read("./index.html"),
    read("./privacy.html"),
    read("./terms.html"),
  ]);
  assert.match(home, /\/privacy\.html/);
  assert.match(home, /\/terms\.html/);
  assert.match(home, /play\.google\.com\/apps\/testing\/dev\.osholt\.tideandseek/);
  assert.match(home, /testflight\.apple\.com/);
  assert.match(privacy, /privacy@tailendcharlie\.app/);
  assert.match(terms, /support@tailendcharlie\.app/);
});
