const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

initializeApp();

/**
 * Marks the caller's phone number as verified, making sure no other account
 * has ever claimed it (one account per person).
 *
 * Call after the SMS code has been linked to the signed-in user. The number is
 * read from the caller's Auth record, which Firebase only sets after a
 * successful code check, so it can't be spoofed by the client.
 *
 * Claims live in phoneNumbers/{e164 number} and are never released, so a
 * number can't be reused even if the original account unlinks it later.
 * Clients have no access to that collection; this function uses admin access.
 */
exports.confirmPhoneVerified = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in before verifying your phone.');
  }

  const { phoneNumber } = await getAuth().getUser(uid);
  if (!phoneNumber) {
    throw new HttpsError('failed-precondition', 'No verified phone number is linked to this account.');
  }

  const db = getFirestore();
  const phoneRef = db.collection('phoneNumbers').doc(phoneNumber);
  const userRef = db.collection('users').doc(uid);

  await db.runTransaction(async (tx) => {
    const [phoneDoc, userDoc] = await Promise.all([tx.get(phoneRef), tx.get(userRef)]);

    if (!userDoc.exists) {
      throw new HttpsError('failed-precondition', 'Finish signing up before verifying your phone.');
    }

    const ownerUid = phoneDoc.exists ? phoneDoc.get('uid') : null;
    if (ownerUid && ownerUid !== uid) {
      throw new HttpsError('already-exists', 'This phone number is already used by another account.');
    }

    if (!phoneDoc.exists) {
      tx.create(phoneRef, { uid, claimedAt: FieldValue.serverTimestamp() });
    }
    tx.update(userRef, { phoneVerified: true, phoneNumber });
  });

  return { phoneNumber };
});
