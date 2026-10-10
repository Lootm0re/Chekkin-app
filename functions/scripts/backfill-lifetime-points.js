// One-off: set users/{uid}.lifetimePoints from the current points for users
// that don't have it yet (everyone from before it existed). Each change also
// updates the user's public profile through syncPublicProfile. Uses the
// firebase CLI's login, so run `firebase login` first. Safe to re-run: users
// that already have lifetimePoints, e.g. set by a check-in or a redemption
// since the functions were deployed, are left alone.
//
//   node scripts/backfill-lifetime-points.js [--dry-run]

const { cliFirestore } = require('./cli-firestore');

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const db = cliFirestore();
  const users = await db.collection('users').get();
  const missing = users.docs.filter((d) => typeof d.get('lifetimePoints') !== 'number');
  console.log(`${users.size} users, ${missing.length} without lifetimePoints.`);
  if (dryRun) {
    for (const user of missing) console.log(`  @${user.get('username')}: ${user.get('points') ?? 0}`);
    return;
  }

  let set = 0;
  for (const user of missing) {
    // In a transaction, so a check-in at the same moment isn't lost.
    const done = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(user.ref);
      if (!fresh.exists || typeof fresh.get('lifetimePoints') === 'number') return false;
      tx.update(user.ref, { lifetimePoints: fresh.get('points') ?? 0 });
      return true;
    });
    if (done) set += 1;
  }
  console.log(`Set lifetimePoints for ${set} users.`);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
