// Set partner tiers. A restaurant, café, hotel or shop can only be checked in
// to once it's a partner: its claim approved (scripts/business-claims.js) and
// a tier set here. Uses the firebase CLI's login, so run `firebase login`
// first.
//
//   node scripts/partner-tiers.js list
//   node scripts/partner-tiers.js set <placeId> <basic|premium|platinum|diamond>
//   node scripts/partner-tiers.js remove <placeId>   (no longer a partner)
//
// Tiers: Basic 25 points a check-in, 100 check-ins a month; Premium 50 and
// 500; Platinum 75 and 1,500; Diamond 100, unlimited. Past the monthly
// budget, check-ins earn 5. Keep in sync with TIERS in index.js.
//
// Billing will set the same businesses/{placeId}.tier field later, so keep
// this script and that field as they are.
//
// Founding Partner offer: the first 50 businesses to become partners
// (approved, with a tier) get any plan free for 3 months, cancellable at any
// time; Platinum and Diamond then get 50% off for 3 more months. The
// foundingPartnerOffer function hands out the numbers when a tier is first
// set here, and works out the discount from the tier at the end of the free
// months, so a tier change before then moves the discount with it. `list`
// shows each place's offer. Nobody is charged yet: billing isn't built.

const { FieldValue } = require('@google-cloud/firestore'); // installed with firebase-admin
const { cliFirestore } = require('./cli-firestore');

const TIERS = { basic: 100, premium: 500, platinum: 1500, diamond: null };

function formatDate(timestamp) {
  return timestamp ? timestamp.toDate().toISOString().slice(0, 10) : '';
}

/** E.g. 'founding #3, free until 2027-01-22, 50% off until 2027-04-22'. */
function foundingOffer(business) {
  if (business.get('foundingPartner') !== true) return '';
  return [
    `founding #${business.get('foundingNumber')}`,
    `free until ${formatDate(business.get('freeUntil'))}`,
    business.get('discountUntil') ? `50% off until ${formatDate(business.get('discountUntil'))}` : '',
    business.get('offerCancelledAt') ? `cancelled ${formatDate(business.get('offerCancelledAt'))}` : '',
  ].filter(Boolean).join(', ');
}

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
      foundingOffer(business),
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
  if (business.get('foundingPartner') === undefined) {
    console.log('If Founding Partner numbers are left, it gets the next one in a moment (see `list`).');
  } else if (business.get('foundingPartner') === true && !business.get('offerCancelledAt') &&
      business.get('freeUntil')?.toMillis() > Date.now()) {
    console.log('Still in its free months, so its Founding Partner discount follows the new tier.');
  }
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
  console.log('Usage: node scripts/partner-tiers.js list | set <placeId> <basic|premium|platinum|diamond> | remove <placeId>');
  process.exitCode = 1;
}

main().catch((err) => { console.error(err.message); process.exit(1); });
