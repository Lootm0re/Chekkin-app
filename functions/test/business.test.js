// Tests for the owner's business tools: creating check-in codes in batches
// (createBusinessCodes, getBusinessCodes) with the hourly safety limit, and
// the business leaderboard (getBusinessLeaderboard). Run with `npm test`
// (Firestore emulator, demo- project), so nothing reaches production.

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

const PROJECT = process.env.GCLOUD_PROJECT ?? '';
const EMULATOR = process.env.FIRESTORE_EMULATOR_HOST;
if (!EMULATOR || !PROJECT.startsWith('demo-')) {
  throw new Error('Run these tests with `npm test`: they need the Firestore emulator and a demo- project.');
}

const { createBusinessCodes, getBusinessCodes, getBusinessLeaderboard } = require('../index.js');
const logger = require('firebase-functions/logger');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

const db = getFirestore();
const ANDROID_APP_ID = '1:929780239850:android:528c6d1770ddd6cd45f693';

beforeEach(async () => {
  const res = await fetch(
    `http://${EMULATOR}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  assert.ok(res.ok, 'clearing the emulator failed');
});

function call(fn, uid, data) {
  return fn.run({ auth: { uid, token: {} }, app: { appId: ANDROID_APP_ID }, data });
}

async function addPartner(placeId, ownerUid, tier, fields = {}) {
  await db.doc(`businesses/${placeId}`).set({
    status: 'approved', tier, ownerUid, placeName: placeId, category: 'restaurant', ...fields,
  });
}

/** Months as the server keys them (Europe/Stockholm). */
function monthKey(ms) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Stockholm', year: 'numeric', month: '2-digit' })
    .format(new Date(ms)).slice(0, 7);
}
const THIS_MONTH = monthKey(Date.now());
const LAST_MONTH = (() => {
  const [y, m] = THIS_MONTH.split('-').map(Number);
  return m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, '0')}`;
})();

async function setCheckIns(placeId, used, month = THIS_MONTH) {
  await db.doc(`placeBudgets/${placeId}_${month}`).set({ placeId, month, used });
}

// --- Creating codes ------------------------------------------------------------

test('creates 1, 10 or 50 unique 8-digit codes, and nothing else', async () => {
  await addPartner('cafe', 'owner1', 'basic');
  for (const count of [1, 10, 50]) {
    const { codes, expiresAt } = await call(createBusinessCodes, 'owner1', { placeId: 'cafe', count });
    assert.equal(codes.length, count);
    assert.equal(new Set(codes).size, count);
    assert.ok(codes.every((c) => /^\d{8}$/.test(c)));
    assert.ok(Math.abs(expiresAt - (Date.now() + 24 * 3600 * 1000)) < 60 * 1000);
  }
  const listed = await call(getBusinessCodes, 'owner1', { placeId: 'cafe' });
  assert.equal(listed.activeCount, 61);
  assert.equal(listed.codes.length, 61);

  for (const count of [0, 2, 51, 100, '10']) {
    await assert.rejects(call(createBusinessCodes, 'owner1', { placeId: 'cafe', count }), { code: 'invalid-argument' });
  }
  // No budget is used by creating codes.
  assert.equal((await db.collection('placeBudgets').get()).size, 0);
});

test('lists only unused, unexpired codes', async () => {
  await addPartner('cafe', 'owner1', 'basic');
  const { codes } = await call(createBusinessCodes, 'owner1', { placeId: 'cafe', count: 10 });
  const ref = (code) => db.doc(`businessSecrets/cafe/codes/${code}`);
  await ref(codes[0]).update({ usedAt: Timestamp.now(), usedBy: 'u1' });
  await ref(codes[1]).update({ expiresAt: Timestamp.fromMillis(Date.now() - 1000) });

  const listed = await call(getBusinessCodes, 'owner1', { placeId: 'cafe' });
  assert.equal(listed.activeCount, 8);
  const shown = listed.codes.map((c) => c.code);
  assert.ok(!shown.includes(codes[0]) && !shown.includes(codes[1]));
});

test('only the owner of an approved place can create or list its codes', async () => {
  await addPartner('cafe', 'owner1', 'basic');
  await addPartner('pending', 'owner2', null, { status: 'pending' });
  await assert.rejects(call(createBusinessCodes, 'someoneElse', { placeId: 'cafe', count: 1 }),
    { code: 'permission-denied' });
  await assert.rejects(call(getBusinessCodes, 'someoneElse', { placeId: 'cafe' }), { code: 'permission-denied' });
  await assert.rejects(call(createBusinessCodes, 'owner2', { placeId: 'pending', count: 1 }),
    { code: 'failed-precondition' });
});

test('refuses politely past 1,000 codes an hour, logs it and raises one alert', async () => {
  await addPartner('cafe', 'owner1', 'diamond');
  const hour = new Date().toISOString().slice(0, 13);
  await db.doc(`businessSecrets/cafe/codeQuota/${hour}`).set({ hour, count: 990 });

  const warnings = [];
  const realWarn = logger.warn;
  logger.warn = (message, details) => warnings.push({ message, details });
  try {
    // 990 + 10 = 1,000 is still allowed.
    await call(createBusinessCodes, 'owner1', { placeId: 'cafe', count: 10 });
    await assert.rejects(call(createBusinessCodes, 'owner1', { placeId: 'cafe', count: 1 }),
      { code: 'resource-exhausted', message: /up to 1,000 codes an hour.*Codes you already have still work/ });
    await assert.rejects(call(createBusinessCodes, 'owner1', { placeId: 'cafe', count: 50 }),
      { code: 'resource-exhausted' });
  } finally {
    logger.warn = realWarn;
  }

  assert.equal(warnings.length, 2);
  assert.equal(warnings[0].message, 'Business code hourly limit reached');
  assert.equal(warnings[0].details.placeId, 'cafe');
  assert.equal(warnings[0].details.limit, 1000);
  const alerts = await db.collection('alerts').where('type', '==', 'codeHourlyLimit').get();
  assert.equal(alerts.size, 1, 'one alert per place per hour');
  assert.equal(alerts.docs[0].get('placeId'), 'cafe');
  // Nothing was created by the refused calls.
  assert.equal((await call(getBusinessCodes, 'owner1', { placeId: 'cafe' })).activeCount, 10);
});

test('a batch that would pass the limit is refused whole, a smaller one still fits', async () => {
  await addPartner('cafe', 'owner1', 'basic');
  const hour = new Date().toISOString().slice(0, 13);
  await db.doc(`businessSecrets/cafe/codeQuota/${hour}`).set({ hour, count: 960 });
  const realWarn = logger.warn;
  logger.warn = () => {};
  try {
    await assert.rejects(call(createBusinessCodes, 'owner1', { placeId: 'cafe', count: 50 }),
      { code: 'resource-exhausted', message: /You can create 40 more this hour/ });
  } finally {
    logger.warn = realWarn;
  }
  assert.equal((await call(createBusinessCodes, 'owner1', { placeId: 'cafe', count: 10 })).codes.length, 10);
});

// --- Leaderboard -------------------------------------------------------------------

test('ranks a place against its own tier by check-ins this month, with top 5 and neighbours', async () => {
  // Seven basic places, so Basic is a league of its own.
  const counts = { b1: 70, b2: 60, b3: 50, b4: 40, b5: 30, mine: 20, b7: 10 };
  for (const [id, used] of Object.entries(counts)) {
    await addPartner(id, id === 'mine' ? 'owner1' : `owner-${id}`, 'basic');
    await setCheckIns(id, used);
  }
  // A busy diamond place in another league, and last month's numbers, are ignored.
  for (const id of ['d1', 'd2', 'd3', 'd4', 'd5']) await addPartner(id, `owner-${id}`, 'diamond');
  await setCheckIns('d1', 999);
  await setCheckIns('mine', 500, LAST_MONTH);

  const result = await call(getBusinessLeaderboard, 'owner1', { placeId: 'mine' });

  assert.deepEqual(result.league, { tiers: ['basic'], label: 'Basic', size: 7 });
  assert.deepEqual(result.top.map((r) => [r.rank, r.placeName, r.checkIns]),
    [[1, 'b1', 70], [2, 'b2', 60], [3, 'b3', 50], [4, 'b4', 40], [5, 'b5', 30]]);
  assert.deepEqual(result.you, { rank: 6, placeName: 'mine', checkIns: 20, isYou: true });
  assert.deepEqual(result.above, { rank: 5, placeName: 'b5', checkIns: 30, isYou: false });
  assert.deepEqual(result.below, { rank: 7, placeName: 'b7', checkIns: 10, isYou: false });
  assert.equal(result.month, THIS_MONTH);
  // Last month: 'mine' had the most check-ins in its league.
  assert.equal(result.lastMonthWinner, true);
  // Nothing beyond names, ranks and counts.
  assert.deepEqual(Object.keys(result).sort(),
    ['above', 'below', 'lastMonthWinner', 'league', 'month', 'top', 'you']);
  for (const row of [...result.top, result.you, result.above, result.below]) {
    assert.deepEqual(Object.keys(row).sort(), ['checkIns', 'isYou', 'placeName', 'rank']);
  }
});

test('a tier with fewer than 5 places joins the next tier up; a short top league joins the one below', async () => {
  // 2 premium + 3 platinum = one league of 5; 2 diamond is too small and joins it.
  // Basic has 5 of its own.
  const places = {
    bA: 'basic', bB: 'basic', bC: 'basic', bD: 'basic', bE: 'basic',
    p1: 'premium', p2: 'premium', pl1: 'platinum', pl2: 'platinum', pl3: 'platinum', d1: 'diamond', d2: 'diamond',
  };
  for (const [id, tier] of Object.entries(places)) await addPartner(id, `owner-${id}`, tier);
  await setCheckIns('d1', 5);
  await setCheckIns('p1', 3);

  const premium = await call(getBusinessLeaderboard, 'owner-p2', { placeId: 'p2' });
  assert.deepEqual(premium.league, { tiers: ['premium', 'platinum', 'diamond'], label: 'Premium & Platinum & Diamond', size: 7 });
  assert.deepEqual(premium.top.slice(0, 2).map((r) => r.placeName), ['d1', 'p1']);
  // Ties share a rank: the five places with no check-ins are all 3rd.
  assert.deepEqual(premium.you, { rank: 3, placeName: 'p2', checkIns: 0, isYou: true });

  const basic = await call(getBusinessLeaderboard, 'owner-bA', { placeId: 'bA' });
  assert.deepEqual(basic.league.tiers, ['basic']);
  assert.equal(basic.league.size, 5);
});

test('if every tier is small, they all share one league', async () => {
  await addPartner('only', 'owner1', 'platinum');
  await addPartner('other', 'owner2', 'basic');
  const result = await call(getBusinessLeaderboard, 'owner1', { placeId: 'only' });
  assert.deepEqual(result.league.tiers, ['basic', 'platinum']);
  assert.equal(result.league.size, 2);
  assert.equal(result.lastMonthWinner, false, 'no check-ins last month, so no winner');
});

test('refuses callers who don\'t own the place, and places that aren\'t partners', async () => {
  await addPartner('mine', 'owner1', 'basic');
  await addPartner('noTier', 'owner2', null);
  await assert.rejects(call(getBusinessLeaderboard, 'customer', { placeId: 'mine' }), { code: 'permission-denied' });
  await assert.rejects(call(getBusinessLeaderboard, 'owner2', { placeId: 'mine' }), { code: 'permission-denied' });
  await assert.rejects(call(getBusinessLeaderboard, 'owner2', { placeId: 'noTier' }), { code: 'failed-precondition' });
  await assert.rejects(getBusinessLeaderboard.run({ app: { appId: ANDROID_APP_ID }, data: { placeId: 'mine' } }),
    { code: 'unauthenticated' });
});
