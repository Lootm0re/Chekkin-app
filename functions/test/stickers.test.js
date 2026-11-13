// Tests for table stickers: checking in by scanning one (performCheckIn with
// stickerToken) runs the same checks as a code, wrong and old stickers count
// towards the lockout, the hourly limits, the owner's sticker functions, and
// the rules keeping stickers server-only. Run with `npm test` (Firestore
// emulator, demo- project), so nothing reaches production. The Places API is
// stubbed with the places below.

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
  restaurant: { id: 'testRestaurant', name: 'Test Restaurant', latitude: 59.3300, longitude: 18.0700, primaryType: 'restaurant' },
  cafe: { id: 'testCafe', name: 'Test Cafe', latitude: 59.3310, longitude: 18.0710, primaryType: 'cafe' },
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

const {
  performCheckIn, createTableSticker, getTableStickers, resetTableStickers, createBusinessCodes,
} = require('../index.js');
const logger = require('firebase-functions/logger');
const { getFirestore } = require('firebase-admin/firestore');
const { asUser } = require('./as-user');

const db = getFirestore();
const ANDROID_APP_ID = '1:929780239850:android:528c6d1770ddd6cd45f693';
const OWNER = 'owner1';

beforeEach(async () => {
  const res = await realFetch(
    `http://${EMULATOR}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  assert.ok(res.ok, 'clearing the emulator failed');
});

function asCaller(fn, uid, data) {
  return fn.run({ auth: { uid, token: {} }, app: { appId: ANDROID_APP_ID }, data });
}

async function addUser(uid) {
  await db.doc(`users/${uid}`).set({ name: uid, username: uid, phoneVerified: true, points: 0 });
}

async function addPartner(place, tier = 'basic', ownerUid = OWNER) {
  await db.doc(`businesses/${place.id}`).set({
    status: 'approved', tier, ownerUid, placeName: place.name, category: 'restaurant', codeSeq: 1,
  });
  await db.doc(`businessSecrets/${place.id}`).set({ secret: crypto.randomBytes(20).toString('base64'), seq: 1 });
}

/** The owner adds a sticker for [label] at [place]; returns it ({ id, label, token }). */
async function newSticker(place, label = 'Table 4', ownerUid = OWNER) {
  const { stickers } = await asCaller(createTableSticker, ownerUid, { placeId: place.id, label });
  return stickers.find((s) => s.label === label);
}

/** A device fix [metersNorth] of [place]. */
function fixAt(place, { metersNorth = 5, accuracy = 10, ageSeconds = 5, mocked = false } = {}) {
  return {
    deviceLatitude: place.latitude + metersNorth / 111195,
    deviceLongitude: place.longitude,
    deviceAccuracy: accuracy,
    deviceTimestamp: Date.now() - ageSeconds * 1000,
    deviceIsMocked: mocked,
  };
}

/** [uid] scans [token] at [place] and checks in. */
function scan(uid, place, token, fixOptions) {
  return asCaller(performCheckIn, uid, { placeId: place.id, ...fixAt(place, fixOptions), stickerToken: token });
}

const points = async (uid) => (await db.doc(`users/${uid}`).get()).get('points');
const failures = async (uid, place) => (await db.doc(`users/${uid}/codeAttempts/${place.id}`).get()).get('failures') ?? 0;

/** [token] with its payload changed by [edit] but the old signature. */
function tampered(token, edit) {
  const [prefix, payload, signature] = token.split('.');
  const claims = edit(JSON.parse(Buffer.from(payload, 'base64url').toString()));
  return [prefix, Buffer.from(JSON.stringify(claims)).toString('base64url'), signature].join('.');
}

// --- Checking in with a sticker ------------------------------------------------------

test('a valid scan checks in like a code, and the token holds no code or personal data', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);

  const [prefix, payload] = sticker.token.split('.');
  assert.equal(prefix, 'CHK1');
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url').toString()),
    { p: 'testRestaurant', s: sticker.id, t: 'Table 4', v: 1 });

  const result = await scan('u1', PLACES.restaurant, sticker.token);
  assert.equal(result.pointsEarned, 25);
  assert.equal(await points('u1'), 25);
  const checkIns = await db.collection('checkIns').get();
  assert.equal(checkIns.size, 1);
  assert.equal(checkIns.docs[0].get('via'), 'sticker');
  // The sticker isn't used up: another guest can scan it too.
  await addUser('u2');
  assert.equal((await scan('u2', PLACES.restaurant, sticker.token)).pointsEarned, 25);
});

test('the 8-digit code still works as a fallback next to stickers', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  await newSticker(PLACES.restaurant);
  const { codes } = await asCaller(createBusinessCodes, OWNER, { placeId: PLACES.restaurant.id, count: 1 });
  const result = await asCaller(performCheckIn, 'u1', { placeId: PLACES.restaurant.id, ...fixAt(PLACES.restaurant), code: codes[0] });
  assert.equal(result.pointsEarned, 25);
  assert.equal((await db.collection('checkIns').get()).docs[0].get('via'), 'code');
});

test('a sticker from another place is refused and counts as a wrong try', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  await addPartner(PLACES.cafe, 'basic', 'owner2');
  const cafeSticker = await newSticker(PLACES.cafe, 'Table 1', 'owner2');

  await assert.rejects(scan('u1', PLACES.restaurant, cafeSticker.token),
    { code: 'invalid-argument', message: /for another place, not Test Restaurant.*4 tries left/ });
  assert.equal(await failures('u1', PLACES.restaurant), 1);
  assert.equal(await points('u1'), 0);
});

test('after "Reset all stickers", old ones are refused and the reprinted ones work', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const old = await newSticker(PLACES.restaurant);

  const reset = await asCaller(resetTableStickers, OWNER, { placeId: PLACES.restaurant.id });
  assert.equal(reset.version, 2);
  const reprinted = reset.stickers.find((s) => s.id === old.id);
  assert.equal(reprinted.label, 'Table 4', 'the same tables get new stickers');
  assert.notEqual(reprinted.token, old.token);

  await assert.rejects(scan('u1', PLACES.restaurant, old.token),
    { code: 'invalid-argument', message: /has been replaced/ });
  assert.equal(await failures('u1', PLACES.restaurant), 1);
  assert.equal((await scan('u1', PLACES.restaurant, reprinted.token)).pointsEarned, 25);
});

test('the location checks still apply: too far away or mocked is refused, and the scan isn\'t counted', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);

  await assert.rejects(scan('u1', PLACES.restaurant, sticker.token, { metersNorth: 30 }),
    { code: 'failed-precondition', message: /Too far away.*currently 30m/ });
  await assert.rejects(scan('u1', PLACES.restaurant, sticker.token, { mocked: true }),
    { code: 'failed-precondition', message: /simulated/ });
  await assert.rejects(scan('u1', PLACES.restaurant, sticker.token, { accuracy: 51 }),
    { code: 'failed-precondition', message: /only accurate to 51m/ });
  await assert.rejects(scan('u1', PLACES.restaurant, sticker.token, { ageSeconds: 180 }),
    { code: 'failed-precondition', message: /out of date/ });
  assert.equal(await points('u1'), 0);
  assert.equal((await db.doc('users/u1/stickerScans/quota').get()).exists, false, 'refused before the sticker step');
  assert.equal(await failures('u1', PLACES.restaurant), 0);
});

test('a second scan at the same place within 24 hours is refused', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);
  await scan('u1', PLACES.restaurant, sticker.token);
  await assert.rejects(scan('u1', PLACES.restaurant, sticker.token),
    { code: 'already-exists', message: /already checked in at Test Restaurant today/ });
  assert.equal(await points('u1'), 25);
});

test('the owner can\'t check in at their own place with its sticker', async () => {
  await addUser(OWNER);
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);
  await assert.rejects(scan(OWNER, PLACES.restaurant, sticker.token),
    { code: 'permission-denied', message: /since you manage it/ });
  assert.equal(await points(OWNER), 0);
});

test('past the monthly check-in budget, a scan earns 5 points, like a code', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant, 'platinum');
  const sticker = await newSticker(PLACES.restaurant);
  const month = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Stockholm', year: 'numeric', month: '2-digit' })
    .format(new Date()).slice(0, 7);
  await db.doc(`placeBudgets/${PLACES.restaurant.id}_${month}`).set({ placeId: PLACES.restaurant.id, month, used: 1500 });

  const result = await scan('u1', PLACES.restaurant, sticker.token);
  assert.equal(result.pointsEarned, 5);
  assert.equal(result.budgetUsedUp, true);
});

test('forged or tampered stickers are refused, and 5 wrong tries lock codes out too', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);
  const forged = [
    tampered(sticker.token, (c) => ({ ...c, t: 'Table 9' })),
    tampered(sticker.token, (c) => ({ ...c, v: 2 })),
    sticker.token.slice(0, -4) + 'AAAA',
    'https://example.com/not-a-sticker',
  ];
  const messages = [/isn't one of Test Restaurant's/, /isn't one of Test Restaurant's/, /isn't one of Test Restaurant's/, /isn't a Chekkin table sticker/];
  for (const [i, token] of forged.entries()) {
    await assert.rejects(scan('u1', PLACES.restaurant, token), { code: 'invalid-argument', message: messages[i] });
  }
  await assert.rejects(scan('u1', PLACES.restaurant, forged[0]),
    { code: 'resource-exhausted', message: /Too many wrong codes or stickers/ });
  // Locked out: the real sticker and a real code are refused too.
  await assert.rejects(scan('u1', PLACES.restaurant, sticker.token), { code: 'resource-exhausted' });
  const { codes } = await asCaller(createBusinessCodes, OWNER, { placeId: PLACES.restaurant.id, count: 1 });
  await assert.rejects(asCaller(performCheckIn, 'u1', { placeId: PLACES.restaurant.id, ...fixAt(PLACES.restaurant), code: codes[0] }),
    { code: 'resource-exhausted', message: /Too many wrong codes/ });
  assert.equal(await points('u1'), 0);
});

// --- Rate limits ---------------------------------------------------------------------

test('a sticker pauses after 30 check-ins in an hour, with one alert', async () => {
  await addUser('u1');
  await addUser('u2');
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);
  const hour = new Date().toISOString().slice(0, 13);
  await db.doc(`businessSecrets/${PLACES.restaurant.id}/stickers/${sticker.id}`).update({ hour, checkInsThisHour: 30 });

  const warnings = [];
  const realWarn = logger.warn;
  logger.warn = (message, details) => warnings.push({ message, details });
  try {
    for (const uid of ['u1', 'u2']) {
      await assert.rejects(scan(uid, PLACES.restaurant, sticker.token),
        { code: 'resource-exhausted', message: /used a lot this hour.*Ask the staff at Test Restaurant for a code/ });
    }
  } finally {
    logger.warn = realWarn;
  }
  assert.equal(warnings.filter((w) => w.message === 'Table sticker hourly limit reached').length, 2);
  const alerts = await db.collection('alerts').where('type', '==', 'stickerHourlyLimit').get();
  assert.equal(alerts.size, 1, 'one alert per sticker per hour');
  assert.equal(alerts.docs[0].get('label'), 'Table 4');
  assert.equal(await failures('u1', PLACES.restaurant), 0, 'not the guest\'s fault: no wrong try');
  assert.equal(await points('u1'), 0);
});

test('a user can scan at most 10 stickers an hour, valid or not', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);
  await db.doc('users/u1/stickerScans/quota').set({ hour: new Date().toISOString().slice(0, 13), count: 10 });

  const realWarn = logger.warn;
  logger.warn = () => {};
  try {
    await assert.rejects(scan('u1', PLACES.restaurant, sticker.token),
      { code: 'resource-exhausted', message: /scanned a lot of stickers this hour/ });
  } finally {
    logger.warn = realWarn;
  }
  assert.equal(await points('u1'), 0);
  // A new hour starts again.
  await db.doc('users/u1/stickerScans/quota').set({ hour: '2000-01-01T00', count: 10 });
  assert.equal((await scan('u1', PLACES.restaurant, sticker.token)).pointsEarned, 25);
});

// --- The owner's stickers ----------------------------------------------------------------

test('owners create stickers by table label; the list never includes the signing key', async () => {
  await addPartner(PLACES.restaurant);
  await newSticker(PLACES.restaurant, '  Table   4 ');
  await newSticker(PLACES.restaurant, 'Terrace 2');
  const list = await asCaller(getTableStickers, OWNER, { placeId: PLACES.restaurant.id });
  assert.deepEqual(list.stickers.map((s) => s.label), ['Table 4', 'Terrace 2']);
  assert.equal(list.placeName, 'Test Restaurant');
  assert.equal(list.version, 1);
  assert.ok(!JSON.stringify(list).includes((await db.doc(`businessSecrets/${PLACES.restaurant.id}`).get()).get('stickerKey')));

  for (const label of ['', '   ', 'x'.repeat(31), 42]) {
    await assert.rejects(asCaller(createTableSticker, OWNER, { placeId: PLACES.restaurant.id, label }),
      { code: 'invalid-argument' });
  }
  await assert.rejects(asCaller(createTableSticker, OWNER, { placeId: PLACES.restaurant.id, label: 'table 4' }),
    { code: 'already-exists' });
});

test('only the owner of an approved place can create, list or reset its stickers', async () => {
  await addPartner(PLACES.restaurant);
  await db.doc(`businesses/${PLACES.cafe.id}`).set({ status: 'pending', ownerUid: 'owner2', placeName: 'Test Cafe' });
  const data = { placeId: PLACES.restaurant.id, label: 'Table 1' };
  for (const fn of [createTableSticker, getTableStickers, resetTableStickers]) {
    await assert.rejects(asCaller(fn, 'someoneElse', data), { code: 'permission-denied' });
    await assert.rejects(asCaller(fn, 'owner2', { placeId: PLACES.cafe.id, label: 'Table 1' }), { code: 'failed-precondition' });
    await assert.rejects(fn.run({ app: { appId: ANDROID_APP_ID }, data }), { code: 'unauthenticated' });
  }
  assert.equal((await db.collection(`businessSecrets/${PLACES.restaurant.id}/stickers`).get()).size, 0);
});

test('rules: nobody reads or writes stickers, sticker keys or scan counts from the app', async () => {
  await addUser('u1');
  await addPartner(PLACES.restaurant);
  const sticker = await newSticker(PLACES.restaurant);
  await scan('u1', PLACES.restaurant, sticker.token);

  const paths = [
    `businessSecrets/${PLACES.restaurant.id}`,
    `businessSecrets/${PLACES.restaurant.id}/stickers/${sticker.id}`,
    'users/u1/stickerScans/quota',
    `users/u1/codeAttempts/${PLACES.restaurant.id}`,
  ];
  for (const path of paths) {
    for (const uid of [OWNER, 'u1']) {
      assert.equal((await asUser(uid, path)).status, 403, `read ${path} as ${uid}`);
      const write = await asUser(uid, path, { method: 'PATCH', fields: { label: { stringValue: 'x' } } });
      assert.equal(write.status, 403, `write ${path} as ${uid}`);
    }
  }
  const newSticker2 = await asUser(OWNER, `businessSecrets/${PLACES.restaurant.id}/stickers/fake`,
    { method: 'PATCH', fields: { label: { stringValue: 'Table 9' } } });
  assert.equal(newSticker2.status, 403);
  assert.equal((await db.doc(`businessSecrets/${PLACES.restaurant.id}/stickers/${sticker.id}`).get()).get('label'), 'Table 4');
});
