// Tests for the Founding Partner offer: numbers handed out by the
// foundingPartnerOffer trigger (never more than 50, even at the same moment),
// the date maths, the discount following plan changes until the free months
// end, cancelFoundingOffer, and the rules keeping the fields server-only.
// Run with `npm test` (Firestore emulator, demo- project), so nothing reaches
// production.

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

const PROJECT = process.env.GCLOUD_PROJECT ?? '';
const EMULATOR = process.env.FIRESTORE_EMULATOR_HOST;
if (!EMULATOR || !PROJECT.startsWith('demo-')) {
  throw new Error('Run these tests with `npm test`: they need the Firestore emulator and a demo- project.');
}

const { foundingPartnerOffer, cancelFoundingOffer } = require('../index.js');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');
const { asUser } = require('./as-user');

const db = getFirestore();
const ANDROID_APP_ID = '1:929780239850:android:528c6d1770ddd6cd45f693';
const COUNTER = 'counters/foundingPartners';

beforeEach(async () => {
  const res = await fetch(
    `http://${EMULATOR}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  assert.ok(res.ok, 'clearing the emulator failed');
});

function call(fn, uid, data) {
  return fn.run({ auth: { uid, token: {} }, app: { appId: ANDROID_APP_ID }, data });
}

const business = (placeId) => db.doc(`businesses/${placeId}`);

async function addBusiness(placeId, fields = {}) {
  await business(placeId).set({
    status: 'approved', ownerUid: `owner-${placeId}`, placeName: placeId, category: 'restaurant', ...fields,
  });
}

/** Runs the trigger as Firestore would after a write at [time], given the document before it. */
async function runTrigger(placeId, time, before) {
  const after = await business(placeId).get();
  return foundingPartnerOffer.run({
    params: { placeId }, time: new Date(time).toISOString(), data: { before, after },
  });
}

/** Changes a business at [time] and runs the trigger for that write. */
async function change(placeId, fields, time) {
  const before = await business(placeId).get();
  await business(placeId).update(fields);
  await runTrigger(placeId, time, before);
  return (await business(placeId).get()).data();
}

/** Becomes a partner with [tier] at [time]. */
async function becomePartner(placeId, tier, time, fields = {}) {
  await addBusiness(placeId, { tier, ...fields });
  await runTrigger(placeId, time);
  return (await business(placeId).get()).data();
}

const iso = (timestamp) => timestamp?.toDate().toISOString();
const NOW = Date.parse('2026-10-22T10:15:00Z'); // 12:15 in Stockholm (summer time)

// --- Handing out the offer ---------------------------------------------------------

test('a new partner gets the next number, free for 3 months; Basic and Premium get no discount', async () => {
  for (const [placeId, tier, number] of [['basic', 'basic', 1], ['premium', 'premium', 2]]) {
    const data = await becomePartner(placeId, tier, NOW);
    assert.equal(data.foundingPartner, true);
    assert.equal(data.foundingNumber, number);
    // Same time of day in Stockholm: 12:15 summer time is 10:15 UTC, 12:15 winter time 11:15 UTC.
    assert.equal(iso(data.freeUntil), '2027-01-22T11:15:00.000Z');
    assert.equal(data.discountUntil, undefined);
    assert.equal(data.offerCancelledAt, undefined);
  }
  assert.equal((await db.doc(COUNTER).get()).get('count'), 2);
});

test('Platinum and Diamond also get 50% off for the 3 months after the free ones', async () => {
  for (const tier of ['platinum', 'diamond']) {
    const data = await becomePartner(tier, tier, NOW);
    assert.equal(iso(data.freeUntil), '2027-01-22T11:15:00.000Z');
    assert.equal(iso(data.discountUntil), '2027-04-22T10:15:00.000Z', 'back on summer time in April');
  }
});

test('only partners get it: not pending, rejected or approved places without a plan', async () => {
  await addBusiness('pending', { status: 'pending', tier: 'diamond' });
  await addBusiness('rejected', { status: 'rejected', tier: 'diamond' });
  await addBusiness('noPlan');
  for (const placeId of ['pending', 'rejected', 'noPlan']) {
    await runTrigger(placeId, NOW);
    assert.equal((await business(placeId).get()).get('foundingPartner'), undefined, placeId);
  }
  assert.equal((await db.doc(COUNTER).get()).exists, false);

  // Approved later with a plan: the offer starts then.
  const data = await change('noPlan', { tier: 'basic' }, Date.parse('2026-11-05T09:00:00Z'));
  assert.equal(data.foundingNumber, 1);
  assert.equal(iso(data.freeUntil), '2027-02-05T09:00:00.000Z');
});

test('running again, or for other writes, never gives a second number', async () => {
  await becomePartner('cafe', 'premium', NOW);
  await runTrigger('cafe', NOW);
  await change('cafe', { codeSeq: 7 }, NOW + 1000);
  await change('cafe', { tier: 'basic' }, NOW + 2000);
  const data = (await business('cafe').get()).data();
  assert.equal(data.foundingNumber, 1);
  assert.equal((await db.doc(COUNTER).get()).get('count'), 1);
});

test('at the limit: sign-ups at the same moment share the last numbers, never number 51', async () => {
  await db.doc(COUNTER).set({ count: 45 });
  const placeIds = Array.from({ length: 8 }, (_, i) => `place${i}`);
  await Promise.all(placeIds.map((p) => addBusiness(p, { tier: 'platinum' })));
  await Promise.all(placeIds.map((p) => runTrigger(p, NOW)));

  const docs = await Promise.all(placeIds.map((p) => business(p).get()));
  const numbers = docs.filter((d) => d.get('foundingPartner') === true).map((d) => d.get('foundingNumber'));
  assert.deepEqual(numbers.sort((a, b) => a - b), [46, 47, 48, 49, 50]);
  const without = docs.filter((d) => d.get('foundingPartner') === false);
  assert.equal(without.length, 3);
  assert.ok(without.every((d) => d.get('foundingNumber') === undefined && d.get('freeUntil') === undefined));
  assert.equal((await db.doc(COUNTER).get()).get('count'), 50);

  // After 50, new partners simply get no offer.
  const late = await becomePartner('late', 'diamond', NOW + 60000);
  assert.equal(late.foundingPartner, false);
  assert.equal((await db.doc(COUNTER).get()).get('count'), 50);
});

// --- Date maths ------------------------------------------------------------------------

test('3 calendar months in Stockholm time: short months, leap years, the new year and midnight', async () => {
  const cases = [
    // Approved (UTC)              free until (UTC)             discount until (UTC)
    ['2026-11-30T12:00:00Z', '2027-02-28T12:00:00.000Z', '2027-05-28T11:00:00.000Z'], // no 30 Feb
    ['2027-11-30T12:00:00Z', '2028-02-29T12:00:00.000Z', '2028-05-29T11:00:00.000Z'], // leap year
    ['2026-12-31T08:00:00Z', '2027-03-31T07:00:00.000Z', '2027-06-30T07:00:00.000Z'], // into summer time; no 31 Jun
    ['2026-10-21T22:30:00Z', '2027-01-21T23:30:00.000Z', '2027-04-21T22:30:00.000Z'], // 00:30 on 22 Oct in Stockholm stays 22 Jan
    ['2026-10-01T10:00:00Z', '2027-01-01T11:00:00.000Z', '2027-04-01T10:00:00.000Z'], // over the new year
  ];
  for (const [i, [approved, freeUntil, discountUntil]] of cases.entries()) {
    const data = await becomePartner(`p${i}`, 'diamond', Date.parse(approved));
    assert.equal(iso(data.freeUntil), freeUntil, approved);
    assert.equal(iso(data.discountUntil), discountUntil, approved);
  }
});

// --- Plan changes ----------------------------------------------------------------------

test('a plan change during the free months moves the discount with it', async () => {
  await becomePartner('cafe', 'premium', NOW);
  const later = NOW + 30 * 24 * 3600 * 1000;

  let data = await change('cafe', { tier: 'platinum' }, later);
  assert.equal(iso(data.discountUntil), '2027-04-22T10:15:00.000Z', 'upgraded: discount added');
  data = await change('cafe', { tier: 'diamond' }, later + 1000);
  assert.equal(iso(data.discountUntil), '2027-04-22T10:15:00.000Z', 'still a discount tier');
  data = await change('cafe', { tier: 'basic' }, later + 2000);
  assert.equal(data.discountUntil, undefined, 'downgraded: discount gone');
  data = await change('cafe', { status: 'rejected', tier: 'platinum' }, later + 3000);
  assert.equal(data.discountUntil, undefined, 'not a partner: no plan to discount');
  data = await change('cafe', { status: 'approved' }, later + 4000);
  assert.equal(iso(data.discountUntil), '2027-04-22T10:15:00.000Z');
  assert.equal(data.foundingNumber, 1, 'the number never changes');
  assert.equal(iso(data.freeUntil), '2027-01-22T11:15:00.000Z', 'nor the free months');
});

test('after the free months, the plan they ended on decides: later changes don\'t move it', async () => {
  await becomePartner('up', 'platinum', NOW);
  await becomePartner('down', 'basic', NOW);
  const afterFree = Date.parse('2027-01-22T11:15:00Z'); // freeUntil exactly

  let data = await change('up', { tier: 'basic' }, afterFree);
  assert.equal(iso(data.discountUntil), '2027-04-22T10:15:00.000Z', 'kept: Platinum when the free months ended');
  data = await change('down', { tier: 'diamond' }, afterFree + 1000);
  assert.equal(data.discountUntil, undefined, 'none: Basic when the free months ended');
});

// --- Cancelling ------------------------------------------------------------------------

test('the owner can cancel at any time; it\'s immediate and keeps the number', async () => {
  await becomePartner('cafe', 'platinum', NOW);
  const before = Date.now();
  const { cancelledAt } = await call(cancelFoundingOffer, 'owner-cafe', { placeId: 'cafe' });
  assert.ok(cancelledAt >= before - 1000 && cancelledAt <= Date.now() + 1000);

  let data = (await business('cafe').get()).data();
  assert.equal(data.offerCancelledAt.toMillis(), cancelledAt);
  assert.equal(data.foundingPartner, true);
  assert.equal(data.foundingNumber, 1);
  assert.equal(data.tier, 'platinum', 'the plan itself is left to billing');

  // Cancelling again changes nothing; a plan change no longer moves the discount.
  assert.equal((await call(cancelFoundingOffer, 'owner-cafe', { placeId: 'cafe' })).cancelledAt, cancelledAt);
  data = await change('cafe', { tier: 'basic' }, NOW + 1000);
  assert.equal(iso(data.discountUntil), '2027-04-22T10:15:00.000Z');
  assert.equal((await db.doc(COUNTER).get()).get('count'), 1, 'the number isn\'t given to anyone else');
});

test('only the owner can cancel, and only an offer that exists', async () => {
  await becomePartner('cafe', 'basic', NOW);
  await db.doc(COUNTER).set({ count: 50 });
  await becomePartner('late', 'basic', NOW);

  await assert.rejects(call(cancelFoundingOffer, 'someoneElse', { placeId: 'cafe' }), { code: 'permission-denied' });
  await assert.rejects(call(cancelFoundingOffer, 'owner-late', { placeId: 'late' }), { code: 'failed-precondition' });
  await assert.rejects(call(cancelFoundingOffer, 'owner-cafe', { placeId: 'missing' }), { code: 'permission-denied' });
  await assert.rejects(cancelFoundingOffer.run({ app: { appId: ANDROID_APP_ID }, data: { placeId: 'cafe' } }),
    { code: 'unauthenticated' });
  await assert.rejects(
    cancelFoundingOffer.run({ auth: { uid: 'owner-cafe', token: {} }, app: { appId: 'web' }, data: { placeId: 'cafe' } }),
    { code: 'permission-denied' }, 'only from the apps');
  assert.equal((await business('cafe').get()).get('offerCancelledAt'), undefined);
});

// --- Rules -----------------------------------------------------------------------------

test('rules: owners read their offer, but only the server can write it or the counter', async () => {
  await becomePartner('cafe', 'platinum', NOW);
  assert.equal((await asUser('owner-cafe', 'businesses/cafe')).status, 200);
  assert.equal((await asUser('someoneElse', 'businesses/cafe')).status, 403);

  const attempts = {
    foundingNumber: { integerValue: '1' },
    foundingPartner: { booleanValue: true },
    freeUntil: { timestampValue: '2030-01-01T00:00:00Z' },
    discountUntil: { timestampValue: '2030-01-01T00:00:00Z' },
    offerCancelledAt: { nullValue: null },
  };
  for (const [field, value] of Object.entries(attempts)) {
    const res = await asUser('owner-cafe', 'businesses/cafe', { method: 'PATCH', fields: { [field]: value } });
    assert.equal(res.status, 403, field);
  }
  assert.equal((await asUser('owner-cafe', 'counters/foundingPartners')).status, 403);
  const counterWrite = await asUser('owner-cafe', 'counters/foundingPartners',
    { method: 'PATCH', fields: { count: { integerValue: '0' } } });
  assert.equal(counterWrite.status, 403);

  const data = (await business('cafe').get()).data();
  assert.equal(data.foundingNumber, 1);
  assert.equal(iso(data.freeUntil), '2027-01-22T11:15:00.000Z');
  assert.equal((await db.doc(COUNTER).get()).get('count'), 1);
});
