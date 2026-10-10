// Fills the local emulators with test data for the voucher flow: @gaian
// (owns Pizzeria La Fleur), @gais (a customer with 12,000 points) and
// @partner2 (owns Trattoria Test), the rewards catalog, an expired voucher
// and another partner's voucher. Clears the emulators first, so it can be
// re-run to start over. All three accounts use the password below.
//
// Run by scripts/emulators.sh, or while the emulators are running:
//   npm run emulators:reseed
//
// It only ever writes to the emulators: it refuses to run unless the project
// is a demo- project (which can't reach any real Firebase service) and both
// Firestore and Auth are pointed at emulators on this machine.

const PASSWORD = 'chekkin-test';

const PROJECT = process.env.GCLOUD_PROJECT ?? '';
const FIRESTORE_HOST = process.env.FIRESTORE_EMULATOR_HOST ?? '';
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? '';

function refuse(reason) {
  console.error(`Not seeding: ${reason}\nThis script only writes to the local emulators (see its header).`);
  process.exit(1);
}

function isLocal(hostAndPort) {
  return /^(localhost|127\.0\.0\.1|\[::1\]):\d+$/.test(hostAndPort);
}

if (!PROJECT.startsWith('demo-')) refuse(`the project is "${PROJECT}", not a demo- project.`);
if (!isLocal(FIRESTORE_HOST)) refuse('FIRESTORE_EMULATOR_HOST isn\'t set to an emulator on this machine.');
if (!isLocal(AUTH_HOST)) refuse('FIREBASE_AUTH_EMULATOR_HOST isn\'t set to an emulator on this machine.');

const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');
const crypto = require('crypto');
const { CATALOG } = require('./rewards-catalog');

initializeApp({ projectId: PROJECT });
const db = getFirestore();
const DAY_MS = 24 * 3600 * 1000;

const LA_FLEUR = { id: 'ChIJXYvnQaR-X0YR4f368TTVJbU', name: 'Pizzeria La Fleur' };
const TRATTORIA = { id: 'emulatorTrattoriaTest', name: 'Trattoria Test' };

const USERS = [
  { uid: 'gaian', name: 'Gaian', points: 0 },
  { uid: 'gais', name: 'Gais', points: 12000 },
  { uid: 'partner2', name: 'Partner Two', points: 0 },
];

async function clearEmulators() {
  for (const url of [
    `http://${FIRESTORE_HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`,
    `http://${AUTH_HOST}/emulator/v1/projects/${PROJECT}/accounts`,
  ]) {
    const res = await fetch(url, { method: 'DELETE' });
    if (!res.ok) throw new Error(`Clearing ${url} failed: ${res.status}`);
  }
}

async function addUser({ uid, name, points }) {
  const email = `${uid}@chekkin.test`;
  await getAuth().createUser({ uid, email, password: PASSWORD, displayName: name });
  await db.doc(`users/${uid}`).set({
    name, username: uid, email, points, lifetimePoints: points, phoneVerified: true,
    createdAt: Timestamp.now(), homeLastChanged: Timestamp.now(),
  });
  // So the web build may use the app-only functions (throwUnlessFromApp).
  await db.doc(`devTesters/${uid}`).set({ username: uid, addedAt: Timestamp.now() });
}

async function addPartner(place, ownerUid) {
  await db.doc(`businesses/${place.id}`).set({
    ownerUid, status: 'approved', tier: 'basic', placeName: place.name, category: 'restaurant',
    requestedAt: Timestamp.now(), approvedAt: Timestamp.now(), codeSeq: 0,
  });
  await db.doc(`businessSecrets/${place.id}`).set({ secret: crypto.randomBytes(20).toString('base64'), seq: 0 });
}

async function addVoucher(code, place, { expiresInDays }) {
  const reward = CATALOG['restaurant-discount'];
  const now = Date.now();
  await db.doc(`vouchers/${code}`).set({
    code, userId: 'gais', username: 'gais', partnerPlaceId: place.id, placeName: place.name,
    rewardId: 'restaurant-discount', rewardName: reward.name, discountPercent: reward.discountPercent,
    pointsCost: reward.pointsCost,
    createdAt: Timestamp.fromMillis(now + (expiresInDays - reward.validDays) * DAY_MS),
    expiresAt: Timestamp.fromMillis(now + expiresInDays * DAY_MS),
    usedAt: null,
  });
}

async function main() {
  await clearEmulators();
  for (const user of USERS) await addUser(user);
  await addPartner(LA_FLEUR, 'gaian');
  await addPartner(TRATTORIA, 'partner2');
  for (const [id, reward] of Object.entries(CATALOG)) await db.doc(`rewards/${id}`).set(reward);
  // Expired yesterday, at @gaian's place.
  await addVoucher('EXPDTEST', LA_FLEUR, { expiresInDays: -1 });
  // Valid, but for another partner, so @gaian's Verify voucher counts it as wrong.
  await addVoucher('THERTEST', TRATTORIA, { expiresInDays: 29 });

  console.log(`Seeded ${PROJECT}. Sign in with password "${PASSWORD}" as:`);
  console.log('  gais@chekkin.test      customer, 12000 points');
  console.log(`  gaian@chekkin.test     owns ${LA_FLEUR.name}`);
  console.log(`  partner2@chekkin.test  owns ${TRATTORIA.name}`);
  console.log(`Vouchers: EXPDTEST (expired, ${LA_FLEUR.name}), THERTEST (valid, ${TRATTORIA.name}).`);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
