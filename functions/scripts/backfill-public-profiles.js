// One-off: create publicProfiles/{uid} for users that existed before the
// syncPublicProfile trigger. Uses the firebase CLI's login, so run
// `firebase login` first. Safe to re-run.
//
//   node scripts/backfill-public-profiles.js [--dry-run]

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { Firestore } = require('@google-cloud/firestore'); // installed with firebase-admin
const { OAuth2Client } = require('google-auth-library');

const firebaseTools = path.join(execSync('npm root -g').toString().trim(), 'firebase-tools');
const configstore = require(path.join(firebaseTools, 'lib/configstore')).configstore;
const api = require(path.join(firebaseTools, 'lib/api'));

// Same fields as PUBLIC_PROFILE_FIELDS in index.js.
const PUBLIC_PROFILE_FIELDS = ['name', 'username', 'points', 'profilePictureUrl'];

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const projectId = JSON.parse(fs.readFileSync(path.join(__dirname, '../../.firebaserc'), 'utf8')).projects.default;
  const tokens = configstore.get('tokens');
  if (!tokens?.refresh_token) throw new Error('Not logged in - run `firebase login` first.');

  // The Admin SDK only takes service-account or default credentials, so use
  // the Firestore client directly with the CLI's OAuth login.
  const authClient = new OAuth2Client({ clientId: api.clientId(), clientSecret: api.clientSecret() });
  authClient.setCredentials({ refresh_token: tokens.refresh_token });
  const db = new Firestore({ projectId, authClient });
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
