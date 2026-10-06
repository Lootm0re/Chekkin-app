// Set partner tiers. A restaurant, café, hotel or shop can only be checked in
// to once it's a partner: its claim approved (scripts/business-claims.js) and
// a tier set here. Uses the firebase CLI's login, so run `firebase login`
// first.
//
//   node scripts/partner-tiers.js list
//   node scripts/partner-tiers.js set <placeId> <basic|premium|diamond>
//   node scripts/partner-tiers.js remove <placeId>   (no longer a partner)
//
// Tiers: Basic 25 points a check-in, 100 check-ins a month; Premium 50 and
// 500; Diamond 100, unlimited. Past the monthly budget, check-ins earn 5.
// Keep in sync with TIERS in index.js.

const { FieldValue } = require('@google-cloud/firestore'); // installed with firebase-admin
const { cliFirestore } = require('./cli-firestore');

const TIERS = { basic: 100, premium: 500, diamond: null };

function thisMonth() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Stockholm', year: 'numeric', month: '2-digit' })
    .format(new Date()).slice(0, 7);
}

async function list(db) {
  const businesses = await db.collection('businesses').where('status', '==', 'approved').get();
  if (businesses.empty) {
    console.log('No approved businesses.');
    return;
  }
  const month = thisMonth();
  const budgets = await db.getAll(...businesses.docs.map((b) => db.collection('placeBudgets').doc(`${b.id}_${month}`)));
  businesses.docs.forEach((business, i) => {
    const tier = business.get('tier');
    const budget = tier ? TIERS[tier] : undefined;
    const used = budgets[i].exists ? budgets[i].get('used') ?? 0 : 0;
    console.log([
      (tier ?? 'not a partner').padEnd(13),
      business.id,
      `${business.get('placeName')} (${business.get('category')})`,
      tier ? `${used}${budget === null ? '' : `/${budget}`} check-ins in ${month}` : '',
    ].join('  '));
  });
}

async function set(db, placeId, tier) {
  if (!Object.hasOwn(TIERS, tier)) throw new Error(`Tier must be one of: ${Object.keys(TIERS).join(', ')}.`);
  const ref = db.collection('businesses').doc(placeId);
  const business = await ref.get();
  if (!business.exists) throw new Error(`No claim for ${placeId}.`);
  if (business.get('status') !== 'approved') {
    throw new Error(`${business.get('placeName')} isn't approved, so nobody can show its check-in codes. ` +
      'Approve it with business-claims.js first.');
  }
  await ref.update({ tier, tierSetAt: FieldValue.serverTimestamp() });
  console.log(`${business.get('placeName')} is now a ${tier} partner.`);
}

async function remove(db, placeId) {
  const ref = db.collection('businesses').doc(placeId);
  const business = await ref.get();
  if (!business.exists) throw new Error(`No claim for ${placeId}.`);
  await ref.update({ tier: FieldValue.delete(), tierSetAt: FieldValue.serverTimestamp() });
  console.log(`${business.get('placeName')} is no longer a partner. Check-ins there are closed.`);
}

async function main() {
  const [command, placeId, tier] = process.argv.slice(2);
  const db = cliFirestore();
  if (command === 'list') return list(db);
  if (command === 'set' && placeId && tier) return set(db, placeId, tier);
  if (command === 'remove' && placeId) return remove(db, placeId);
  console.log('Usage: node scripts/partner-tiers.js list | set <placeId> <basic|premium|diamond> | remove <placeId>');
  process.exitCode = 1;
}

main().catch((err) => { console.error(err.message); process.exit(1); });
