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
let placesApiCalls = 0;
globalThis.fetch = async (url, options) => {
  const match = /^https:\/\/places\.googleapis\.com\/v1\/places\/([^/?]+)$/.exec(String(url));
  if (match) placesApiCalls++;
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

const { performCheckIn, createBusinessCodes } = require('../index.js');
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

async function addPartner(place, tier = 'basic') {
  await db.doc(`businesses/${place.id}`).set({ status: 'approved', tier, ownerUid: OWNER_UID, codeSeq: 1 });
  await db.doc(`businessSecrets/${place.id}`).set({
    secret: crypto.randomBytes(20).toString('base64'), seq: 1, issuedAt: Timestamp.now(),
  });
}

/** Has the owner create [count] 8-digit codes for [place]; returns them. */
async function newCodes(place, count = 1) {
  const result = await createBusinessCodes.run({
    auth: { uid: OWNER_UID, token: {} },
    app: { appId: ANDROID_APP_ID },
    data: { placeId: place.id, count },
  });
  return result.codes;
}

async function budgetUsed(place) {
  const budgets = await db.collection('placeBudgets').where('placeId', '==', place.id).get();
  return budgets.empty ? 0 : budgets.docs[0].get('used');
}

/** The place's legacy 6-digit code, the same way the function derives it (HOTP). */
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
    { code: 'invalid-argument', message: /isn't right, has expired or has already been used/ });
  assert.equal((await db.doc('users/u2').get()).get('points'), 0);
});

test('8-digit codes from a batch each work once, and only check-ins count against the budget', async () => {
  await addUser('u1');
  await addUser('u2');
  await addPartner(PLACES.restaurant);
  const codes = await newCodes(PLACES.restaurant, 10);
  assert.equal(codes.length, 10);
  assert.ok(codes.every((c) => /^\d{8}$/.test(c)));
  assert.equal(await budgetUsed(PLACES.restaurant), 0, 'creating codes costs nothing');

  const first = await checkIn('u1', PLACES.restaurant, {}, { code: codes[3] });
  assert.equal(first.pointsEarned, 25);
  assert.equal(await budgetUsed(PLACES.restaurant), 1);
  // Used up: nobody else can use it.
  await assert.rejects(checkIn('u2', PLACES.restaurant, {}, { code: codes[3] }),
    { code: 'invalid-argument', message: /isn't right, has expired or has already been used/ });
  // Another code from the same batch still works.
  await checkIn('u2', PLACES.restaurant, {}, { code: codes[7] });
  assert.equal(await budgetUsed(PLACES.restaurant), 2);
  const used = await db.doc(`businessSecrets/${PLACES.restaurant.id}/codes/${codes[7]}`).get();
  assert.equal(used.get('usedBy'), 'u2');
});

test('an 8-digit code expires 24 hours after it was created', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const [code] = await newCodes(PLACES.restaurant);
  const ref = db.doc(`businessSecrets/${PLACES.restaurant.id}/codes/${code}`);
  const created = (await ref.get()).get('createdAt').toMillis();
  assert.equal((await ref.get()).get('expiresAt').toMillis() - created, 24 * 3600 * 1000);

  await ref.update({ expiresAt: Timestamp.fromMillis(Date.now() - 1000) });
  await assert.rejects(checkIn('u1', PLACES.restaurant, {}, { code }),
    { code: 'invalid-argument', message: /has expired/ });
});

test('a legacy 6-digit code still works until it expires, and no new one replaces it', async () => {
  await addUser('u1');
  await addUser('u2');
  await addPartner(PLACES.restaurant);
  const code = await currentCode(PLACES.restaurant);
  await checkIn('u1', PLACES.restaurant, {}, { code });
  const secret = await db.doc(`businessSecrets/${PLACES.restaurant.id}`).get();
  assert.equal(secret.get('issuedAt'), null, 'no next legacy code is issued');
  await assert.rejects(checkIn('u2', PLACES.restaurant, {}, { code: await currentCode(PLACES.restaurant) }),
    { code: 'invalid-argument' });
});

test('a legacy 6-digit code is refused once its 10 minutes are over', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  await db.doc(`businessSecrets/${PLACES.restaurant.id}`)
    .update({ issuedAt: Timestamp.fromMillis(Date.now() - 11 * 60 * 1000) });
  await assert.rejects(checkIn('u1', PLACES.restaurant, {}, { code: await currentCode(PLACES.restaurant) }),
    { code: 'invalid-argument' });
});

test('the owner can\'t check in at their own place, even with a valid code', async () => {
  await addUser(OWNER_UID);
  await addPartner(PLACES.restaurant);
  const [code] = await newCodes(PLACES.restaurant);
  await assert.rejects(checkIn(OWNER_UID, PLACES.restaurant, {}, { code }),
    { code: 'permission-denied', message: /since you manage it/ });
  const doc = await db.doc(`businessSecrets/${PLACES.restaurant.id}/codes/${code}`).get();
  assert.equal(doc.get('usedAt'), null, 'the code is not used up');
});

// --- Tiers -------------------------------------------------------------------------

test('a platinum partner gives 75 points, and 5 once its 1,500 monthly check-ins are used', async () => {
  await addUser('u1');
  await addUser('u2');
  await addPartner(PLACES.restaurant, 'platinum');
  const [first, second] = await newCodes(PLACES.restaurant, 10);
  assert.equal((await checkIn('u1', PLACES.restaurant, {}, { code: first })).pointsEarned, 75);

  const budget = (await db.collection('placeBudgets').where('placeId', '==', PLACES.restaurant.id).get()).docs[0];
  await budget.ref.update({ used: 1500 });
  const late = await checkIn('u2', PLACES.restaurant, {}, { code: second });
  assert.equal(late.pointsEarned, 5);
  assert.equal(late.budgetUsedUp, true);
});

test('premium gives 50 and diamond 100 points', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant, 'premium');
  let [code] = await newCodes(PLACES.restaurant);
  assert.equal((await checkIn('u1', PLACES.restaurant, {}, { code })).pointsEarned, 50);

  await addUser('u2');
  await db.doc(`businesses/${PLACES.restaurant.id}`).update({ tier: 'diamond' });
  [code] = await newCodes(PLACES.restaurant);
  assert.equal((await checkIn('u2', PLACES.restaurant, {}, { code })).pointsEarned, 100);
});

// --- Success ---------------------------------------------------------------------

test('a valid check-in awards points and records it', async () => {
  await addUser('u1');
  const result = await checkIn('u1', PLACES.park);
  assert.equal(result.pointsEarned, 5);
  assert.equal(result.placeName, 'Test Park');

  const user = await db.doc('users/u1').get();
  assert.equal(user.get('points'), 5);
  assert.equal(user.get('lifetimePoints'), 5);
  assert.equal(user.get('lastCheckIn.placeName'), 'Test Park');
  const checkIns = await db.collection('checkIns').where('uid', '==', 'u1').get();
  assert.equal(checkIns.size, 1);
  assert.equal(checkIns.docs[0].get('placeId'), PLACES.park.id);
  assert.equal((await db.doc(`users/u1/placeCheckIns/${PLACES.park.id}`).get()).get('recent').length, 1);
});

test('a check-in raises lifetimePoints too, starting from the points of users from before it existed', async () => {
  await db.doc('users/old').set({ name: 'old', username: 'old', phoneVerified: true, points: 100 });
  await checkIn('old', PLACES.park);
  let user = await db.doc('users/old').get();
  assert.equal(user.get('points'), 105);
  assert.equal(user.get('lifetimePoints'), 105);

  // Partner points too, once the field exists.
  await addPartner(PLACES.restaurant);
  await checkIn('old', PLACES.restaurant, {}, { code: await currentCode(PLACES.restaurant) });
  user = await db.doc('users/old').get();
  assert.equal(user.get('points'), 130);
  assert.equal(user.get('lifetimePoints'), 130);
});

// --- The emulator's stand-in places --------------------------------------------------

// Stand-in coordinates ~11 km from the real Test Park, as the emulator seed
// would write them.
const FAKE_PARK = { ...PLACES.park, latitude: 59.4300, longitude: 18.0686 };

async function addStandInPlace(place) {
  await db.doc(`emulatorPlaces/${place.id}`).set({
    name: place.name, latitude: place.latitude, longitude: place.longitude,
    primaryType: place.primaryType, types: [place.primaryType, 'point_of_interest'],
  });
}

test('production mode ignores the stand-in: the real lookup is used and the fake coordinates are refused', async () => {
  assert.notEqual(process.env.FUNCTIONS_EMULATOR, 'true', 'these tests run like deployed functions');
  await addUser('u1');
  await addStandInPlace(FAKE_PARK);

  // At the stand-in's coordinates, asking for the stand-in: the real Places
  // lookup answers, and the real park is ~11 km away.
  let calls = placesApiCalls;
  await assert.rejects(checkIn('u1', FAKE_PARK, {}, { useEmulatorPlaces: true }),
    { code: 'failed-precondition', message: /Too far away/ });
  assert.equal(placesApiCalls, calls + 1, 'the real Places API was asked');

  // At the real park, with the same flag: an ordinary check-in, real lookup.
  calls = placesApiCalls;
  const result = await checkIn('u1', PLACES.park, {}, { useEmulatorPlaces: true });
  assert.equal(result.pointsEarned, 5);
  assert.equal(placesApiCalls, calls + 1);
});

test('in the functions emulator, only calls from the emulator app use the stand-in places', async () => {
  await addUser('u1');
  await addUser('u2');
  await addStandInPlace(FAKE_PARK);
  const before = process.env.FUNCTIONS_EMULATOR;
  process.env.FUNCTIONS_EMULATOR = 'true';
  try {
    const calls = placesApiCalls;
    // From the emulator app: the stand-in's coordinates count, no Places API call.
    const result = await checkIn('u1', FAKE_PARK, {}, { useEmulatorPlaces: true });
    assert.equal(result.pointsEarned, 5);
    assert.equal(placesApiCalls, calls, 'the Places API was not asked');
    // Without the flag, Places stays off in the emulator, as before.
    await assert.rejects(checkIn('u2', FAKE_PARK), { code: 'unavailable', message: /turned off in the emulators/ });
    assert.equal(placesApiCalls, calls);
  } finally {
    if (before === undefined) delete process.env.FUNCTIONS_EMULATOR;
    else process.env.FUNCTIONS_EMULATOR = before;
  }
});
