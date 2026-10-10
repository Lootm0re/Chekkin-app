// The rewards catalog in rewards/{rewardId}, which redeemReward reads. Uses
// the firebase CLI's login, so run `firebase login` first.
//
//   node scripts/rewards-catalog.js list
//   node scripts/rewards-catalog.js seed              (adds or resets the rewards below)
//   node scripts/rewards-catalog.js active <rewardId> <true|false>
//
// Fields: type ('partner_discount' is the only one redeemReward handles),
// category (partner places of this category; none = any), partnerPlaceId
// (only this place; null = any partner of the category), discountPercent,
// pointsCost, validDays (how long the voucher lasts) and active. The Rewards
// screen shows the active ones.

const { cliFirestore } = require('./cli-firestore');

const CATALOG = {
  'restaurant-discount': {
    name: 'Restaurant Discount',
    description: '50% off at a partner restaurant',
    type: 'partner_discount',
    category: 'restaurant',
    partnerPlaceId: null,
    discountPercent: 50,
    pointsCost: 5000,
    validDays: 30,
    active: true,
  },
};

async function list(db) {
  const rewards = await db.collection('rewards').get();
  if (rewards.empty) {
    console.log('The catalog is empty. Add the rewards with `seed`.');
    return;
  }
  for (const reward of rewards.docs) {
    const r = reward.data();
    console.log([
      (r.active ? 'active' : 'inactive').padEnd(9),
      reward.id,
      `${r.name}: ${r.discountPercent}% off, ${r.pointsCost} points, valid ${r.validDays} days`,
      r.partnerPlaceId ? `at ${r.partnerPlaceId}` : `at any partner ${r.category ?? 'place'}`,
    ].join('  '));
  }
}

async function seed(db) {
  for (const [id, reward] of Object.entries(CATALOG)) {
    await db.collection('rewards').doc(id).set(reward);
    console.log(`Set ${id}.`);
  }
}

async function setActive(db, rewardId, active) {
  const ref = db.collection('rewards').doc(rewardId);
  if (!(await ref.get()).exists) throw new Error(`No reward ${rewardId}.`);
  await ref.update({ active });
  console.log(`${rewardId} is now ${active ? 'active' : 'inactive'}.`);
}

async function main() {
  const [command, rewardId, active] = process.argv.slice(2);
  const db = cliFirestore();
  if (command === 'list') return list(db);
  if (command === 'seed') return seed(db);
  if (command === 'active' && rewardId && ['true', 'false'].includes(active)) {
    return setActive(db, rewardId, active === 'true');
  }
  console.log('Usage: node scripts/rewards-catalog.js list | seed | active <rewardId> <true|false>');
  process.exitCode = 1;
}

module.exports = { CATALOG };

if (require.main === module) {
  main().catch((err) => { console.error(err.message); process.exit(1); });
}
