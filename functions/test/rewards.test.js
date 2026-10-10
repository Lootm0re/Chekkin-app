// Tests for redeeming partner discounts (redeemReward) and owners checking
// the vouchers (verifyVoucher). Run with `npm test` (Firestore emulator,
// demo- project), so nothing reaches production. Neither function calls the
// Places API.

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

const PROJECT = process.env.GCLOUD_PROJECT ?? '';
const EMULATOR = process.env.FIRESTORE_EMULATOR_HOST;
if (!EMULATOR || !PROJECT.startsWith('demo-')) {
  throw new Error('Run these tests with `npm test`: they need the Firestore emulator and a demo- project.');
}

const { redeemReward, verifyVoucher } = require('../index.js');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

const db = getFirestore();
const ANDROID_APP_ID = '1:929780239850:android:528c6d1770ddd6cd45f693';
const REWARD_ID = 'restaurant-discount';
const PLACE = 'testRestaurant';
const OTHER_PLACE = 'otherRestaurant';
const DAY_MS = 24 * 3600 * 1000;

beforeEach(async () => {
  const res = await fetch(
    `http://${EMULATOR}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  assert.ok(res.ok, 'clearing the emulator failed');

  await db.doc(`rewards/${REWARD_ID}`).set({
    name: 'Restaurant Discount', type: 'partner_discount', category: 'restaurant', partnerPlaceId: null,
    discountPercent: 50, pointsCost: 5000, validDays: 30, active: true,
  });
  await addPartner(PLACE, 'owner1', 'Test Restaurant');
  await addPartner(OTHER_PLACE, 'owner2', 'Other Restaurant');
});

async function addUser(uid, points, lifetimePoints = points) {
  await db.doc(`users/${uid}`).set({ name: uid, username: uid, phoneVerified: true, points, lifetimePoints });
}

async function lifetimePointsOf(uid) {
  return (await db.doc(`users/${uid}`).get()).get('lifetimePoints');
}

async function addPartner(placeId, ownerUid, placeName, fields = {}) {
  await db.doc(`businesses/${placeId}`).set({
    status: 'approved', tier: 'basic', ownerUid, placeName, category: 'restaurant', ...fields,
  });
}

async function pointsOf(uid) {
  return (await db.doc(`users/${uid}`).get()).get('points');
}

async function voucherCount() {
  return (await db.collection('vouchers').count().get()).data().count;
}

let requests = 0;

/** Calls redeemReward as [uid] from the Android app, as one tap of Redeem unless [requestId] is given. */
function redeem(uid, { placeId = PLACE, requestId = `tap-${uid}-${++requests}` } = {}) {
  return redeemReward.run({
    auth: { uid, token: {} },
    app: { appId: ANDROID_APP_ID },
    data: { rewardId: REWARD_ID, placeId, requestId },
  });
}

function verify(ownerUid, code) {
  return verifyVoucher.run({
    auth: { uid: ownerUid, token: {} },
    app: { appId: ANDROID_APP_ID },
    data: { code },
  });
}

// --- Redeeming --------------------------------------------------------------

test('refuses to redeem without enough points', async () => {
  await addUser('u1', 4999);
  await assert.rejects(redeem('u1'),
    { code: 'failed-precondition', message: /costs 5000 points\. You have 4999/ });
  assert.equal(await pointsOf('u1'), 4999);
  assert.equal(await voucherCount(), 0);
});

test('refuses a partner that is approved but has no tier', async () => {
  await addUser('u1', 5000);
  await addPartner('freeRestaurant', 'owner3', 'Free Restaurant', { tier: null });
  await assert.rejects(redeem('u1', { placeId: 'freeRestaurant' }),
    { code: 'failed-precondition', message: /can't be used at that place/ });
  assert.equal(await pointsOf('u1'), 5000);
});

test('a double tap of Redeem issues one voucher and takes the points once', async () => {
  await addUser('u1', 12000);
  const [a, b] = await Promise.all([
    redeem('u1', { requestId: 'same-tap-1' }),
    redeem('u1', { requestId: 'same-tap-1' }),
  ]);
  assert.equal(a.code, b.code);
  assert.equal(await pointsOf('u1'), 7000);
  assert.equal(await voucherCount(), 1);
});

test('two redeems at once can\'t spend the same points twice', async () => {
  await addUser('u1', 5000);
  const results = await Promise.allSettled([redeem('u1'), redeem('u1')]);
  assert.deepEqual(results.map((r) => r.status).sort(), ['fulfilled', 'rejected']);
  assert.match(results.find((r) => r.status === 'rejected').reason.message, /You have 0/);
  assert.equal(await pointsOf('u1'), 0);
  assert.equal(await voucherCount(), 1);
});

test('redeeming keeps the points it spent in lifetimePoints, also for users from before it existed', async () => {
  await addUser('u1', 7000, 9000);
  await db.doc('users/old').set({ name: 'old', username: 'old', phoneVerified: true, points: 5500 });
  await redeem('u1');
  await redeem('old');
  assert.equal(await pointsOf('u1'), 2000);
  assert.equal(await lifetimePointsOf('u1'), 9000);
  assert.equal(await pointsOf('old'), 500);
  assert.equal(await lifetimePointsOf('old'), 5500);
});

// --- Verifying --------------------------------------------------------------

test('refuses an expired voucher', async () => {
  await addUser('u1', 5000);
  const { code } = await redeem('u1');
  await db.doc(`vouchers/${code}`).update({ expiresAt: Timestamp.fromMillis(Date.now() - 1000) });
  await assert.rejects(verify('owner1', code), { code: 'failed-precondition', message: /expired/ });
  assert.equal((await db.doc(`vouchers/${code}`).get()).get('usedAt'), null);
});

test('refuses a voucher that was already used', async () => {
  await addUser('u1', 5000);
  const { code } = await redeem('u1');
  await verify('owner1', code);
  await assert.rejects(verify('owner1', code), { code: 'failed-precondition', message: /already used/ });
});

test('refuses another partner\'s voucher as a wrong code, and locks out after 5 wrong codes', async () => {
  await addUser('u1', 5000);
  const { code } = await redeem('u1'); // for owner1's place

  await assert.rejects(verify('owner2', code),
    { code: 'invalid-argument', message: /isn't a voucher for your place\. 4 tries left/ });
  for (let left = 3; left >= 1; left--) {
    await assert.rejects(verify('owner2', 'ZZZZZZZZ'),
      { code: 'invalid-argument', message: new RegExp(`${left} tr(y|ies) left`) });
  }
  await assert.rejects(verify('owner2', 'ZZZZZZZZ'),
    { code: 'resource-exhausted', message: /Too many wrong voucher codes/ });
  // The voucher is untouched and still works at its own place.
  assert.equal((await db.doc(`vouchers/${code}`).get()).get('usedAt'), null);
  assert.equal((await verify('owner1', code)).discountPercent, 50);
});

// --- Success ----------------------------------------------------------------

test('redeeming issues a 30-day voucher, and the owner can use it once', async () => {
  await addUser('u1', 6000);
  const before = Date.now();
  const result = await redeem('u1');

  assert.match(result.code, /^[A-HJ-NP-Z2-9]{8}$/);
  assert.equal(result.discountPercent, 50);
  assert.equal(result.placeName, 'Test Restaurant');
  assert.equal(result.username, 'u1');
  assert.equal(await pointsOf('u1'), 1000);
  assert.equal(await lifetimePointsOf('u1'), 6000);

  const voucher = (await db.doc(`vouchers/${result.code}`).get()).data();
  assert.equal(voucher.userId, 'u1');
  assert.equal(voucher.partnerPlaceId, PLACE);
  assert.equal(voucher.rewardId, REWARD_ID);
  assert.equal(voucher.usedAt, null);
  const lifetime = voucher.expiresAt.toMillis() - voucher.createdAt.toMillis();
  assert.equal(lifetime, 30 * DAY_MS);
  assert.ok(voucher.createdAt.toMillis() >= before);

  // Typed in lower case with a dash, as staff might.
  const typed = `${result.code.slice(0, 4)}-${result.code.slice(4)}`.toLowerCase();
  const verified = await verify('owner1', typed);
  assert.deepEqual(verified,
    { discountPercent: 50, username: 'u1', rewardName: 'Restaurant Discount', placeName: 'Test Restaurant' });
  assert.ok((await db.doc(`vouchers/${result.code}`).get()).get('usedAt'));
});
