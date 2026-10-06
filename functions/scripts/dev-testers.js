// Accounts that skip the check-in location checks (mocked or rough
// positions, impossible travel), so DEV_TOOLS builds can check in from a
// pretend location. Uses the firebase CLI's login, so run `firebase login`
// first.
//
//   node scripts/dev-testers.js list
//   node scripts/dev-testers.js add <username>
//   node scripts/dev-testers.js remove <username>
//
// Testers are stored in devTesters/{uid}, which clients can't read or write.
// They still need to be within range of a place, and are still held to the
// daily limit and business codes.

const { FieldValue } = require('@google-cloud/firestore'); // installed with firebase-admin
const { cliFirestore } = require('./cli-firestore');

async function uidOf(db, username) {
  const users = await db.collection('users').where('username', '==', username.toLowerCase()).limit(1).get();
  if (users.empty) throw new Error(`No user @${username}.`);
  return users.docs[0].id;
}

async function list(db) {
  const testers = await db.collection('devTesters').get();
  if (testers.empty) {
    console.log('No dev testers.');
    return;
  }
  const users = await db.getAll(...testers.docs.map((t) => db.collection('users').doc(t.id)));
  users.forEach((user) => console.log(`@${user.get('username') ?? '?'}  ${user.id}`));
}

async function add(db, username) {
  const uid = await uidOf(db, username);
  await db.collection('devTesters').doc(uid).set({ username, addedAt: FieldValue.serverTimestamp() });
  console.log(`@${username} now skips the location checks.`);
}

async function remove(db, username) {
  const uid = await uidOf(db, username);
  await db.collection('devTesters').doc(uid).delete();
  console.log(`@${username} is checked like everyone else again.`);
}

async function main() {
  const [command, username] = process.argv.slice(2);
  const db = cliFirestore();
  if (command === 'list') return list(db);
  if (command === 'add' && username) return add(db, username);
  if (command === 'remove' && username) return remove(db, username);
  console.log('Usage: node scripts/dev-testers.js list | add <username> | remove <username>');
  process.exitCode = 1;
}

main().catch((err) => { console.error(err.message); process.exit(1); });
