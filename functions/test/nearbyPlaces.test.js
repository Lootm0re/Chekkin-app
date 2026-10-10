// Tests for nearbyPlaces' per-user limit on Places API searches. Run with
// `npm test` (Firestore emulator, demo- project); the Places API is stubbed
// and counts how often it's called.

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

const PROJECT = process.env.GCLOUD_PROJECT ?? '';
const EMULATOR = process.env.FIRESTORE_EMULATOR_HOST;
if (!EMULATOR || !PROJECT.startsWith('demo-')) {
  throw new Error('Run these tests with `npm test`: they need the Firestore emulator and a demo- project.');
}

const { GoogleAuth } = require('google-auth-library');
GoogleAuth.prototype.getClient = async () => ({ getAccessToken: async () => ({ token: 'test' }) });

let searches = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, options) => {
  if (String(url) === 'https://places.googleapis.com/v1/places:searchNearby') {
    searches += 1;
    return new Response(JSON.stringify({
      places: [{
        id: 'testPark', displayName: { text: 'Test Park' }, location: { latitude: 59.3293, longitude: 18.0686 },
        types: ['park'], primaryType: 'park',
      }],
    }));
  }
  if (String(url).includes('googleapis.com')) throw new Error(`Unexpected request in tests: ${url}`);
  return realFetch(url, options);
};

const { nearbyPlaces } = require('../index.js');
const { getFirestore } = require('firebase-admin/firestore');

const db = getFirestore();

beforeEach(async () => {
  searches = 0;
  const res = await realFetch(
    `http://${EMULATOR}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  assert.ok(res.ok, 'clearing the emulator failed');
});

function search(uid) {
  return nearbyPlaces.run({ auth: { uid, token: {} }, data: { latitude: 59.3293, longitude: 18.0686 } });
}

test('allows 20 searches an hour per user, then refuses without calling Places', async () => {
  for (let i = 0; i < 20; i++) {
    const { places } = await search('u1');
    assert.equal(places[0].name, 'Test Park');
  }
  await assert.rejects(search('u1'), { code: 'resource-exhausted', message: /refreshed the map a lot/ });
  assert.equal(searches, 20);
  // Other users have their own limit.
  await search('u2');
  assert.equal(searches, 21);
});

test('dev testers have no limit', async () => {
  await db.doc('devTesters/tester').set({ username: 'tester' });
  for (let i = 0; i < 21; i++) await search('tester');
  assert.equal(searches, 21);
  assert.equal((await db.doc('placesQuota/tester').get()).exists, false);
});

test('refuses once the daily limit is used, even in a new hour', async () => {
  const quota = db.doc('placesQuota/u1');
  await search('u1');
  const { day } = (await quota.get()).data();
  await quota.set({ hour: 'an earlier hour', hourCount: 20, day, dayCount: 100 });
  await assert.rejects(search('u1'), { code: 'resource-exhausted', message: /today/ });
  assert.equal(searches, 1);
});
