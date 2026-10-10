// Tests for the server rules performCheckIn applies to a normal user (not in
// devTesters) calling from the Android app. Run with `npm test`, which starts
// the Firestore emulator under a demo- project, so nothing reaches production.
// The Places API is stubbed with the places below.

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');

const PROJECT = process.env.GCLOUD_PROJECT ?? '';
const EMULATOR = process.env.FIRESTORE_EMULATOR_HOST;
if (!EMULATOR || !PROJECT.startsWith('demo-')) {
  throw new Error('Run these tests with `npm test`: they need the Firestore emulator and a demo- project.');
}

// --- Places API stub --------------------------------------------------------

const PLACES = {
  park: { id: 'testPark', name: 'Test Park', latitude: 59.3293, longitude: 18.0686, primaryType: 'park' },
  // ~400 km from the park.
  farPark: { id: 'testFarPark', name: 'Far Park', latitude: 57.7089, longitude: 11.9746, primaryType: 'park' },
  restaurant: { id: 'testRestaurant', name: 'Test Restaurant', latitude: 59.3300, longitude: 18.0700, primaryType: 'restaurant' },
};

const { GoogleAuth } = require('google-auth-library');
GoogleAuth.prototype.getClient = async () => ({ getAccessToken: async () => ({ token: 'test' }) });

const realFetch = globalThis.fetch;
globalThis.fetch = async (url, options) => {
  const match = /^https:\/\/places\.googleapis\.com\/v1\/places\/([^/?]+)$/.exec(String(url));
  if (!match) {
    if (String(url).includes('googleapis.com')) throw new Error(`Unexpected request in tests: ${url}`);
    return realFetch(url, options);
  }
  const place = Object.values(PLACES).find((p) => p.id === match[1]);
  if (!place) return new Response(JSON.stringify({ error: { code: 404 } }), { status: 404 });
  return new Response(JSON.stringify({
    id: place.id,
    displayName: { text: place.name },
    location: { latitude: place.latitude, longitude: place.longitude },
    types: [place.primaryType, 'point_of_interest'],
    primaryType: place.primaryType,
  }));
};

// --- Setup ------------------------------------------------------------------

const { performCheckIn } = require('../index.js');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

const db = getFirestore();
const ANDROID_APP_ID = '1:929780239850:android:528c6d1770ddd6cd45f693';
const OWNER_UID = 'owner1';

beforeEach(async () => {
  const res = await realFetch(
    `http://${EMULATOR}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  assert.ok(res.ok, 'clearing the emulator failed');
});

async function addUser(uid) {
  await db.doc(`users/${uid}`).set({ name: uid, username: uid, phoneVerified: true, points: 0 });
}

async function addPartner(place) {
  await db.doc(`businesses/${place.id}`).set({ status: 'approved', tier: 'basic', ownerUid: OWNER_UID, codeSeq: 1 });
  await db.doc(`businessSecrets/${place.id}`).set({
    secret: crypto.randomBytes(20).toString('base64'), seq: 1, issuedAt: Timestamp.now(),
  });
}

/** The place's current code, the same way the function derives it (HOTP). */
async function currentCode(place) {
  const doc = await db.doc(`businessSecrets/${place.id}`).get();
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(doc.get('seq')));
  const hmac = crypto.createHmac('sha1', Buffer.from(doc.get('secret'), 'base64')).update(message).digest();
  const offset = hmac[hmac.length - 1] & 0xf;
  return String((hmac.readUInt32BE(offset) & 0x7fffffff) % 1e6).padStart(6, '0');
}

function wrongCode(code) {
  return String((Number(code) + 1) % 1e6).padStart(6, '0');
}

/** A device fix [metersNorth] of [place], with sensible defaults. */
function fixAt(place, { metersNorth = 5, accuracy = 10, ageSeconds = 5, mocked = false } = {}) {
  return {
    deviceLatitude: place.latitude + metersNorth / 111195,
    deviceLongitude: place.longitude,
    deviceAccuracy: accuracy,
    deviceTimestamp: Date.now() - ageSeconds * 1000,
    deviceIsMocked: mocked,
  };
}

/** Calls performCheckIn as [uid] from the Android app. */
function checkIn(uid, place, fixOptions, extra = {}) {
  return performCheckIn.run({
    auth: { uid, token: {} },
    app: { appId: ANDROID_APP_ID },
    data: { placeId: place.id, ...fixAt(place, fixOptions), ...extra },
  });
}

// --- Location rules -----------------------------------------------------------

test('refuses a check-in more than 22 m from the place', async () => {
  await addUser('u1');
  await assert.rejects(checkIn('u1', PLACES.park, { metersNorth: 30 }),
    { code: 'failed-precondition', message: /Too far away.*currently 30m/ });
  // Just inside the range works.
  await checkIn('u1', PLACES.park, { metersNorth: 20 });
});

test('refuses a fix less accurate than 50 m', async () => {
  await addUser('u1');
  await assert.rejects(checkIn('u1', PLACES.park, { accuracy: 51 }),
    { code: 'failed-precondition', message: /only accurate to 51m/ });
});

test('refuses a location older than 2 minutes', async () => {
  await addUser('u1');
  await assert.rejects(checkIn('u1', PLACES.park, { ageSeconds: 180 }),
    { code: 'failed-precondition', message: /out of date/ });
});

test('refuses a fix the device flags as mocked', async () => {
  await addUser('u1');
  await assert.rejects(checkIn('u1', PLACES.park, { mocked: true }),
    { code: 'failed-precondition', message: /simulated/ });
});

test('refuses an impossible jump between two check-ins', async () => {
  await addUser('u1');
  await checkIn('u1', PLACES.park);
  await assert.rejects(checkIn('u1', PLACES.farPark),
    { code: 'failed-precondition', message: /Test Park, \d+ km away, too recently/ });
  assert.equal((await db.doc('users/u1').get()).get('points'), 5);
});

// --- Limits -------------------------------------------------------------------

test('refuses a second check-in at the same place within 24 hours', async () => {
  await addUser('u1');
  await checkIn('u1', PLACES.park);
  await assert.rejects(checkIn('u1', PLACES.park),
    { code: 'already-exists', message: /already checked in at Test Park today/ });
  assert.equal((await db.doc('users/u1').get()).get('points'), 5);
});

// --- Business codes -------------------------------------------------------------

test('refuses a wrong business code and locks out after 5 wrong tries', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const code = await currentCode(PLACES.restaurant);
  const bad = wrongCode(code);

  for (let left = 4; left >= 1; left--) {
    await assert.rejects(checkIn('u1', PLACES.restaurant, {}, { code: bad }),
      { code: 'invalid-argument', message: new RegExp(`isn't right.*${left} tr(y|ies) left`) });
  }
  await assert.rejects(checkIn('u1', PLACES.restaurant, {}, { code: bad }),
    { code: 'resource-exhausted', message: /Too many wrong codes/ });
  // Locked out: even the right code is refused, and isn't used up.
  await assert.rejects(checkIn('u1', PLACES.restaurant, {}, { code }),
    { code: 'resource-exhausted', message: /Too many wrong codes/ });
  assert.equal(await currentCode(PLACES.restaurant), code);
  assert.equal((await db.doc('users/u1').get()).get('points'), 0);
});

test('refuses a business code that was already used', async () => {
  await addUser('u1');
  await addUser('u2');
  await addPartner(PLACES.restaurant);
  const code = await currentCode(PLACES.restaurant);

  const first = await checkIn('u1', PLACES.restaurant, {}, { code });
  assert.equal(first.pointsEarned, 25);
  await assert.rejects(checkIn('u2', PLACES.restaurant, {}, { code }),
    { code: 'invalid-argument', message: /isn't right or has already been used/ });
  assert.equal((await db.doc('users/u2').get()).get('points'), 0);
});

// --- Success ---------------------------------------------------------------------

test('a valid check-in awards points and records it', async () => {
  await addUser('u1');
  const result = await checkIn('u1', PLACES.park);
  assert.equal(result.pointsEarned, 5);
  assert.equal(result.placeName, 'Test Park');

  const user = await db.doc('users/u1').get();
  assert.equal(user.get('points'), 5);
  assert.equal(user.get('lastCheckIn.placeName'), 'Test Park');
  const checkIns = await db.collection('checkIns').where('uid', '==', 'u1').get();
  assert.equal(checkIns.size, 1);
  assert.equal(checkIns.docs[0].get('placeId'), PLACES.park.id);
  assert.equal((await db.doc(`users/u1/placeCheckIns/${PLACES.park.id}`).get()).get('recent').length, 1);
});
