// Requests to the Firestore emulator as a signed-in app user, so they go
// through firestore.rules like the app's (the Admin SDK skips the rules).
// The emulator accepts unsigned ID tokens.

const PROJECT = process.env.GCLOUD_PROJECT ?? '';
const EMULATOR = process.env.FIRESTORE_EMULATOR_HOST;

function idToken(uid) {
  const encode = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  return `${encode({ alg: 'none', typ: 'JWT' })}.${encode({
    iss: `https://securetoken.google.com/${PROJECT}`, aud: PROJECT, sub: uid, user_id: uid,
    iat: now, exp: now + 3600, auth_time: now, firebase: { sign_in_provider: 'password' },
  })}.`;
}

/** GETs [path] as [uid], or PATCHes [fields] (Firestore REST values) into it. Returns the response. */
function asUser(uid, path, { method = 'GET', fields } = {}) {
  let url = `http://${EMULATOR}/v1/projects/${PROJECT}/databases/(default)/documents/${path}`;
  const options = { method, headers: { Authorization: `Bearer ${idToken(uid)}` } };
  if (fields) {
    url += '?' + Object.keys(fields).map((f) => `updateMask.fieldPaths=${f}`).join('&');
    options.body = JSON.stringify({ fields });
    options.headers['Content-Type'] = 'application/json';
  }
  return fetch(url, options);
}

module.exports = { asUser };
