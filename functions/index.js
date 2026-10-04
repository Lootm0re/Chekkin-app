const { onCall, HttpsError } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
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
  logger.info('confirmPhoneVerified called', { uid });
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in before verifying your phone.');
  }

  try {
    const { phoneNumber } = await getAuth().getUser(uid);
    logger.info('Auth record read', { uid, phoneNumber });
    if (!phoneNumber) {
      throw new HttpsError('failed-precondition', 'No verified phone number is linked to this account.');
    }

    const db = getFirestore();
    const phoneRef = db.collection('phoneNumbers').doc(phoneNumber);
    const userRef = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {
      const [phoneDoc, userDoc] = await Promise.all([tx.get(phoneRef), tx.get(userRef)]);
      const ownerUid = phoneDoc.exists ? phoneDoc.get('uid') : null;
      logger.info('Transaction read', { uid, userExists: userDoc.exists, phoneOwner: ownerUid });

      if (!userDoc.exists) {
        throw new HttpsError('failed-precondition', 'Finish signing up before verifying your phone.');
      }
      if (ownerUid && ownerUid !== uid) {
        throw new HttpsError('already-exists', 'This phone number is already used by another account.');
      }

      if (!phoneDoc.exists) {
        tx.create(phoneRef, { uid, claimedAt: FieldValue.serverTimestamp() });
      }
      tx.update(userRef, { phoneVerified: true, phoneNumber });
    });

    logger.info('Phone verified', { uid, phoneNumber });
    return { phoneNumber };
  } catch (err) {
    if (err instanceof HttpsError) {
      logger.warn('confirmPhoneVerified rejected', { uid, code: err.code, message: err.message });
      throw err;
    }
    // Anything else would reach the client as a bare "internal" error, so log
    // it in full and pass the reason along.
    logger.error('confirmPhoneVerified failed', { uid, code: err.code, message: err.message, stack: err.stack });
    throw new HttpsError('internal', `Phone verification failed on the server: ${err.message}`, { code: err.code ?? null });
  }
});
