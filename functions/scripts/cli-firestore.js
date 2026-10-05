// Firestore client for admin scripts, signed in with the firebase CLI's
// login (run `firebase login` first). The Admin SDK only takes service-account
// or default credentials, so this uses the Firestore client directly.

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { Firestore } = require('@google-cloud/firestore'); // installed with firebase-admin
const { OAuth2Client } = require('google-auth-library');

function cliFirestore() {
  const firebaseTools = path.join(execSync('npm root -g').toString().trim(), 'firebase-tools');
  const configstore = require(path.join(firebaseTools, 'lib/configstore')).configstore;
  const api = require(path.join(firebaseTools, 'lib/api'));

  const projectId = JSON.parse(fs.readFileSync(path.join(__dirname, '../../.firebaserc'), 'utf8')).projects.default;
  const tokens = configstore.get('tokens');
  if (!tokens?.refresh_token) throw new Error('Not logged in - run `firebase login` first.');

  const authClient = new OAuth2Client({ clientId: api.clientId(), clientSecret: api.clientSecret() });
  authClient.setCredentials({ refresh_token: tokens.refresh_token });
  return new Firestore({ projectId, authClient });
}

module.exports = { cliFirestore };
