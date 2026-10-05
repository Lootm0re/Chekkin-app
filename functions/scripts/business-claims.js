// Review business claims (restaurants, cafés, hotels asking for check-in
// codes). Uses the firebase CLI's login, so run `firebase login` first.
//
//   node scripts/business-claims.js list
//   node scripts/business-claims.js approve <placeId>
//   node scripts/business-claims.js reject <placeId>   (also revokes an approval)
//
// Approving creates the place's code secret; from then on check-ins there
// need the code shown in the owner's app. Rejecting makes the place
// location-only again, and lets anyone claim it.

const crypto = require('crypto');
const { FieldValue } = require('@google-cloud/firestore'); // installed with firebase-admin
const { cliFirestore } = require('./cli-firestore');

async function list(db) {
  const claims = await db.collection('businesses').orderBy('requestedAt').get();
  if (claims.empty) {
    console.log('No business claims.');
    return;
  }
  const owners = await db.getAll(...claims.docs.map((c) => db.collection('users').doc(c.get('ownerUid'))));
  claims.docs.forEach((claim, i) => {
    const owner = owners[i];
    console.log([
      claim.get('status').padEnd(8),
      claim.id,
      `${claim.get('placeName')} (${claim.get('category')})`,
      `owner @${owner.get('username') ?? '?'} ${owner.get('name') ?? ''} ${owner.get('email') ?? ''} ${owner.get('phoneNumber') ?? ''}`,
      `requested ${claim.get('requestedAt')?.toDate().toISOString() ?? '?'}`,
    ].join('  '));
  });
}

async function approve(db, placeId) {
  const businessRef = db.collection('businesses').doc(placeId);
  const secretRef = db.collection('businessSecrets').doc(placeId);
  await db.runTransaction(async (tx) => {
    const [business, secret] = await Promise.all([tx.get(businessRef), tx.get(secretRef)]);
    if (!business.exists) throw new Error(`No claim for ${placeId}.`);
    if (business.get('status') === 'approved') throw new Error(`${business.get('placeName')} is already approved.`);
    tx.update(businessRef, { status: 'approved', approvedAt: FieldValue.serverTimestamp() });
    if (!secret.exists) {
      tx.create(secretRef, { secret: crypto.randomBytes(20).toString('base64'), createdAt: FieldValue.serverTimestamp() });
    }
  });
  console.log(`Approved ${placeId}. Check-ins there now need the owner's code.`);
}

async function reject(db, placeId) {
  const businessRef = db.collection('businesses').doc(placeId);
  const business = await businessRef.get();
  if (!business.exists) throw new Error(`No claim for ${placeId}.`);
  await businessRef.update({ status: 'rejected', rejectedAt: FieldValue.serverTimestamp() });
  console.log(`Rejected ${business.get('placeName')}. It's location-only again.`);
}

async function main() {
  const [command, placeId] = process.argv.slice(2);
  const db = cliFirestore();
  if (command === 'list') return list(db);
  if ((command === 'approve' || command === 'reject') && placeId) {
    return command === 'approve' ? approve(db, placeId) : reject(db, placeId);
  }
  console.log('Usage: node scripts/business-claims.js list | approve <placeId> | reject <placeId>');
  process.exitCode = 1;
}

main().catch((err) => { console.error(err.message); process.exit(1); });
