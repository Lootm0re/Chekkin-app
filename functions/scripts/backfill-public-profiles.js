// One-off: create publicProfiles/{uid} for users that existed before the
// syncPublicProfile trigger. Uses the firebase CLI's login, so run
// `firebase login` first. Safe to re-run.
//
//   node scripts/backfill-public-profiles.js [--dry-run]

const { cliFirestore } = require('./cli-firestore');

// Same fields as PUBLIC_PROFILE_FIELDS in index.js.
const PUBLIC_PROFILE_FIELDS = ['name', 'username', 'points', 'profilePictureUrl'];

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const db = cliFirestore();
  const [users, profiles] = await Promise.all([
    db.collection('users').get(),
    db.collection('publicProfiles').get(),
  ]);
  const existing = new Set(profiles.docs.map((d) => d.id));
  const missing = users.docs.filter((d) => !existing.has(d.id));
  console.log(`${users.size} users, ${existing.size} public profiles, ${missing.length} to create.`);
  if (dryRun || missing.length === 0) return;

  const writer = db.bulkWriter();
  for (const user of missing) {
    const profile = {};
    for (const f of PUBLIC_PROFILE_FIELDS) {
      if (user.get(f) !== undefined) profile[f] = user.get(f);
    }
    // create(), so a profile the trigger wrote meanwhile isn't overwritten.
    writer.create(db.collection('publicProfiles').doc(user.id), profile)
      .catch((err) => { if (err.code !== 6) throw err; }); // 6 = ALREADY_EXISTS
  }
  await writer.close();
  console.log(`Created ${missing.length} public profiles.`);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
