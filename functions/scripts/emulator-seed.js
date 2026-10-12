// Fills the local emulators with test data for the voucher flow and the
// business tools: @gaian (owns Pizzeria La Fleur, a Platinum partner), @gais
// (a customer with 12,000 points) and @partner2 (owns Trattoria Test, Basic),
// the rewards catalog, an expired voucher and another partner's voucher, and
// made-up partners in every tier with check-ins this month and last month,
// for the business leaderboard, and individual check-ins at La Fleur and
// Trattoria for the owners' Today / Last 7 days tiles. Clears the emulators first, so it can be
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

async function addPartner(place, ownerUid, tier, category = 'restaurant', extra = {}) {
  // Approved 90 days ago, so older check-ins count in "Since approval".
  const approvedAt = Timestamp.fromMillis(Date.now() - 90 * DAY_MS);
  await db.doc(`businesses/${place.id}`).set({
    ownerUid, status: 'approved', tier, placeName: place.name, category,
    requestedAt: approvedAt, approvedAt, codeSeq: 0, ...extra,
  });
  await db.doc(`businessSecrets/${place.id}`).set({ secret: crypto.randomBytes(20).toString('base64'), seq: 0 });
}

/** 'YYYY-MM' in Europe/Stockholm, [monthsAgo] months back: the server's budget months. */
function monthKey(monthsAgo = 0) {
  const now = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Stockholm', year: 'numeric', month: '2-digit' })
    .format(new Date()).slice(0, 7);
  const [year, month] = now.split('-').map(Number);
  const index = year * 12 + (month - 1) - monthsAgo;
  return `${Math.floor(index / 12)}-${String((index % 12) + 1).padStart(2, '0')}`;
}

const POINTS = { basic: 25, premium: 50, platinum: 75, diamond: 100 };

/**
 * Individual check-ins (checkIns documents, like performCheckIn writes) by
 * made-up guests, for the owner's Today / Last 7 days / Since approval
 * tiles: [today] in the last hour or so, [week] spread over the 6 days
 * before, and [older] over the weeks before that.
 */
async function addCheckInHistory(place, tier, { today, week, older }) {
  const now = Date.now();
  const times = [
    ...Array.from({ length: today }, (_, i) => now - (10 + i * 12) * 60 * 1000),
    ...Array.from({ length: week }, (_, i) => now - (1 + (i % 6)) * DAY_MS - (i * 37 % 300) * 60 * 1000),
    ...Array.from({ length: older }, (_, i) => now - (8 + (i * 3) % 70) * DAY_MS),
  ];
  const batch = db.batch();
  times.forEach((ms, i) => {
    batch.set(db.collection('checkIns').doc(), {
      uid: `seedGuest${i % 7}`, placeId: place.id, placeName: place.name, tier,
      basePoints: POINTS[tier], points: POINTS[tier], distanceMeters: 8, createdAt: Timestamp.fromMillis(ms),
    });
  });
  await batch.commit();
}

/** Check-ins this month and last, as placeBudgets (what the budget and the business leaderboard count). */
async function addCheckIns(placeId, thisMonth, lastMonth) {
  for (const [month, used] of [[monthKey(0), thisMonth], [monthKey(1), lastMonth]]) {
    if (used > 0) await db.doc(`placeBudgets/${placeId}_${month}`).set({ placeId, month, used });
  }
}

// Made-up partners for the business leaderboard: [id, name, tier, category,
// check-ins this month, last month]. Basic has 6 with Trattoria, a league of
// its own. Premium (3) is too small and joins Platinum (La Fleur and 3
// more); Diamond (2) is too small for the top and joins them too, so La
// Fleur ranks 6th of 9 with places above and below, and won last month.
const LEAGUE_PLACES = [
  ['emulatorBasic1', 'Kaffebaren Söder', 'basic', 'cafe', 88, 70],
  ['emulatorBasic2', 'Hörnkiosken', 'basic', 'shop', 64, 81],
  ['emulatorBasic3', 'Bageri Vete', 'basic', 'cafe', 47, 52],
  ['emulatorBasic4', 'Nudelbaren', 'basic', 'restaurant', 21, 12],
  ['emulatorBasic5', 'Blomsterboden', 'basic', 'shop', 3, 9],
  ['emulatorPremium1', 'Café Lyktan', 'premium', 'cafe', 81, 90],
  ['emulatorPremium2', 'Sushi Nami', 'premium', 'restaurant', 33, 40],
  ['emulatorPremium3', 'Bokhandeln', 'premium', 'shop', 7, 15],
  ['emulatorPlatinum1', 'Restaurang Fyren', 'platinum', 'restaurant', 96, 130],
  ['emulatorPlatinum2', 'Hotell Ankaret', 'platinum', 'hotel', 64, 88],
  ['emulatorPlatinum3', 'Glassbaren', 'platinum', 'cafe', 18, 25],
  ['emulatorDiamond1', 'Grand Hotell Norr', 'diamond', 'hotel', 1284, 1170],
  ['emulatorDiamond2', 'Saluhallen', 'diamond', 'shop', 57, 140],
];

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
  // 6 group check-ins with 15 people in all: 2.5 on average.
  await addPartner(LA_FLEUR, 'gaian', 'platinum', 'restaurant', { groupCount: 6, groupMembers: 15 });
  await addPartner(TRATTORIA, 'partner2', 'basic');
  await addCheckInHistory(LA_FLEUR, 'platinum', { today: 4, week: 18, older: 19 });
  await addCheckInHistory(TRATTORIA, 'basic', { today: 2, week: 6, older: 4 });
  await addCheckIns(LA_FLEUR.id, 41, 1502);
  await addCheckIns(TRATTORIA.id, 12, 30);
  for (const [id, name, tier, category, thisMonth, lastMonth] of LEAGUE_PLACES) {
    await addPartner({ id, name }, `owner-${id}`, tier, category);
    await addCheckIns(id, thisMonth, lastMonth);
  }
  for (const [id, reward] of Object.entries(CATALOG)) await db.doc(`rewards/${id}`).set(reward);
  // Expired yesterday, at @gaian's place.
  await addVoucher('EXPDTEST', LA_FLEUR, { expiresInDays: -1 });
  // Valid, but for another partner, so @gaian's Verify voucher counts it as wrong.
  await addVoucher('THERTEST', TRATTORIA, { expiresInDays: 29 });

  console.log(`Seeded ${PROJECT}. Sign in with password "${PASSWORD}" as:`);
  console.log('  gais@chekkin.test      customer, 12000 points');
  console.log(`  gaian@chekkin.test     owns ${LA_FLEUR.name} (Platinum, 6th in its league, won last month; ` +
    '4 check-ins today, 22 in 7 days, 41 since approval)');
  console.log(`  partner2@chekkin.test  owns ${TRATTORIA.name} (Basic, 5th of 6)`);
  console.log(`Vouchers: EXPDTEST (expired, ${LA_FLEUR.name}), THERTEST (valid, ${TRATTORIA.name}).`);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
