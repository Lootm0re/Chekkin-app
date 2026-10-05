const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
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

// ---------------------------------------------------------------------------
// Public profiles
//
// users/{uid} is private to its owner (email, date of birth, phone, home
// location). The fields other users may see - for the leaderboard and buddy
// check-ins - are mirrored to publicProfiles/{uid}, which only this function
// writes. Points stay authoritative on users/{uid}; the copy follows within
// a few seconds.
// ---------------------------------------------------------------------------

const PUBLIC_PROFILE_FIELDS = ['name', 'username', 'points', 'profilePictureUrl'];

function publicProfileOf(userData) {
  const profile = {};
  for (const field of PUBLIC_PROFILE_FIELDS) {
    if (userData[field] !== undefined) profile[field] = userData[field];
  }
  return profile;
}

// The database is in europe-north2, which Cloud Functions doesn't offer, so
// the trigger runs in the nearest region that does.
exports.syncPublicProfile = onDocumentWritten({
  document: 'users/{uid}',
  region: 'europe-north1',
}, async (event) => {
  const ref = getFirestore().collection('publicProfiles').doc(event.params.uid);
  const after = event.data?.after;
  if (!after?.exists) {
    await ref.delete();
    return;
  }

  const before = event.data.before;
  const profile = publicProfileOf(after.data());
  const unchanged = before?.exists &&
    PUBLIC_PROFILE_FIELDS.every((f) => before.get(f) === after.get(f));
  if (unchanged) return;

  // set() without merge, so a field removed from users disappears here too.
  await ref.set(profile);
});

// ---------------------------------------------------------------------------
// Check-ins
//
// Places come from the Places API (New), called with the function's service
// account so no server API key is needed. The client only ever sends a place
// ID and its own position: the place's location and types are looked up here,
// so they can't be faked.
// ---------------------------------------------------------------------------

const { GoogleAuth } = require('google-auth-library');

const googleAuth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });

const ALLOWED_PLACE_TYPES = [
  'restaurant', 'cafe', 'coffee_shop', 'lodging', 'hotel', 'museum', 'shopping_mall',
  'tourist_attraction', 'park', 'natural_feature', 'zoo', 'art_gallery', 'stadium',
  'amusement_park', 'landmark', 'historical_landmark', 'place_of_worship', 'church',
  'mosque', 'synagogue', 'hindu_temple', 'library',
];
const BLOCKED_PLACE_TYPES = ['premise', 'subpremise', 'residential', 'street_address'];

// searchNearby rejects types it can't filter by (natural_feature, landmark,
// place_of_worship, premise, ...); results are still checked against the full
// lists above.
const SEARCH_INCLUDED_TYPES = [
  'restaurant', 'cafe', 'coffee_shop', 'lodging', 'museum', 'shopping_mall',
  'tourist_attraction', 'park', 'zoo', 'art_gallery', 'stadium', 'amusement_park',
  'historical_landmark', 'church', 'mosque', 'synagogue', 'hindu_temple', 'library',
];

const NEARBY_RADIUS_METERS = 500;
const CHECK_IN_RANGE_METERS = 22; // keep in sync with MapScreen.checkInRangeMeters
const CHECK_IN_COOLDOWN_HOURS = 24; // per user, per place

async function placesRequest(path, { method = 'GET', fieldMask, body }) {
  const client = await googleAuth.getClient();
  const { token } = await client.getAccessToken();
  const res = await fetch(`https://places.googleapis.com/v1/${path}`, {
    method,
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
      'X-Goog-FieldMask': fieldMask,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json();
  if (!res.ok) {
    logger.error('Places API request failed', { path, status: res.status, error: data.error });
    if (res.status === 404 || res.status === 400) {
      throw new HttpsError('not-found', 'That place could not be found.');
    }
    throw new HttpsError('unavailable', 'Couldn\'t load places right now. Please try again.');
  }
  return data;
}

function isCheckInEligible(types) {
  if (types.some((t) => BLOCKED_PLACE_TYPES.includes(t))) return false;
  return types.some((t) => ALLOWED_PLACE_TYPES.includes(t));
}

// Restaurants, cafés and hotels ('business' categories) can require a code
// from staff once the business has claimed its place; everything else
// ('touristic') is location-only. The primary type decides first, so a hotel
// with a restaurant counts as a hotel.
const BUSINESS_CATEGORIES = ['restaurant', 'cafe', 'hotel'];

function categoryOfType(type) {
  if (type === 'lodging' || type === 'hotel' || type.endsWith('_hotel')) return 'hotel';
  if (type === 'cafe' || type === 'coffee_shop') return 'cafe';
  if (type === 'restaurant' || type.endsWith('_restaurant')) return 'restaurant';
  return null;
}

function placeCategory(primaryType, types) {
  return (primaryType && categoryOfType(primaryType)) ??
    ['hotel', 'cafe', 'restaurant'].find((c) => types.some((t) => categoryOfType(t) === c)) ??
    'touristic';
}

const PLACE_FIELDS = ['id', 'displayName', 'location', 'types', 'primaryType'];

function toPlace(p) {
  const types = p.types ?? [];
  return {
    id: p.id,
    name: p.displayName?.text ?? 'Unnamed place',
    latitude: p.location.latitude,
    longitude: p.location.longitude,
    types,
    category: placeCategory(p.primaryType, types),
  };
}

function readPlaceId(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,300}$/.test(value)) {
    throw new HttpsError('invalid-argument', 'A valid place is required.');
  }
  return value;
}

function distanceMeters(lat1, lng1, lat2, lng2) {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Same formula as checkin_app/lib/checkin_points_with_distance.dart: rarer
// places are worth more, multiplied up by how far they are from home.
function rarityPoints(timesCheckedIn) {
  const basePoints = 10;
  if (timesCheckedIn === 0) return basePoints * 100;
  if (timesCheckedIn < 10) return basePoints * 20;
  if (timesCheckedIn < 100) return basePoints * 5;
  return basePoints;
}

function distanceMultiplier(distanceKm) {
  return Math.min(1.0 + (distanceKm / 500) * 0.10, 3.0);
}

function readCoordinates(data, latKey, lngKey) {
  const lat = data?.[latKey];
  const lng = data?.[lngKey];
  if (typeof lat !== 'number' || typeof lng !== 'number' ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    throw new HttpsError('invalid-argument', 'A valid location is required.');
  }
  return { lat, lng };
}

/** Returns check-in eligible places near the given position. */
exports.nearbyPlaces = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Sign in to see places.');
  }
  const { lat, lng } = readCoordinates(request.data, 'latitude', 'longitude');

  const data = await placesRequest('places:searchNearby', {
    method: 'POST',
    fieldMask: PLACE_FIELDS.map((f) => `places.${f}`).join(','),
    body: {
      includedTypes: SEARCH_INCLUDED_TYPES,
      maxResultCount: 20,
      rankPreference: 'DISTANCE',
      locationRestriction: {
        circle: { center: { latitude: lat, longitude: lng }, radius: NEARBY_RADIUS_METERS },
      },
    },
  });

  const places = (data.places ?? []).map(toPlace).filter((p) => isCheckInEligible(p.types));

  // A place needs a code once its business has been approved.
  const businessDocs = places.length === 0 ? [] : await getFirestore().getAll(
    ...places.map((p) => getFirestore().collection('businesses').doc(p.id)));
  places.forEach((p, i) => {
    p.requiresCode = BUSINESS_CATEGORIES.includes(p.category) &&
      businessDocs[i].exists && businessDocs[i].get('status') === 'approved';
  });
  logger.info('nearbyPlaces', { uid: request.auth.uid, found: data.places?.length ?? 0, eligible: places.length });
  return { places };
});

/**
 * Checks the caller in at a place and awards points.
 *
 * The place's location and types come from the Places API, not the client.
 * The caller must be within CHECK_IN_RANGE_METERS of it and can check in at
 * the same place once every CHECK_IN_COOLDOWN_HOURS. At a restaurant, café or
 * hotel whose business has claimed it, the caller must also send the current
 * code from staff (see getBusinessCode).
 */
exports.performCheckIn = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to check in.');
  }
  const placeId = readPlaceId(request.data?.placeId);
  const device = readCoordinates(request.data, 'deviceLatitude', 'deviceLongitude');

  const place = toPlace(await placesRequest(`places/${placeId}`, {
    fieldMask: PLACE_FIELDS.join(','),
  }));
  if (!isCheckInEligible(place.types)) {
    throw new HttpsError('failed-precondition', `${place.name} isn't a place you can check in at.`);
  }

  const distance = distanceMeters(device.lat, device.lng, place.latitude, place.longitude);
  logger.info('performCheckIn', { uid, placeId, place: place.name, distance: Math.round(distance) });
  if (distance > CHECK_IN_RANGE_METERS) {
    throw new HttpsError('failed-precondition',
      `Too far away - get within ${CHECK_IN_RANGE_METERS}m to check in (currently ${Math.round(distance)}m away).`);
  }

  const db = getFirestore();
  if (BUSINESS_CATEGORIES.includes(place.category)) {
    await checkBusinessCode(db, uid, place, request.data?.code);
  }

  const userRef = db.collection('users').doc(uid);
  const placeRef = db.collection('places').doc(placeId);
  const lastCheckInRef = db.collection('users').doc(uid).collection('placeCheckIns').doc(placeId);
  const checkInRef = db.collection('checkIns').doc();

  const pointsEarned = await db.runTransaction(async (tx) => {
    const [userDoc, placeDoc, lastDoc] = await Promise.all([
      tx.get(userRef), tx.get(placeRef), tx.get(lastCheckInRef),
    ]);

    if (!userDoc.exists || userDoc.get('phoneVerified') !== true) {
      throw new HttpsError('failed-precondition', 'Verify your phone number before checking in.');
    }

    const lastAt = lastDoc.exists ? lastDoc.get('lastCheckInAt')?.toMillis() : null;
    if (lastAt && Date.now() - lastAt < CHECK_IN_COOLDOWN_HOURS * 3600 * 1000) {
      throw new HttpsError('already-exists',
        `You've already checked in at ${place.name} today. Try again tomorrow.`);
    }

    const timesCheckedIn = placeDoc.exists ? (placeDoc.get('timesCheckedIn') ?? 0) : 0;
    const homeLat = userDoc.get('homeLatitude');
    const homeLng = userDoc.get('homeLongitude');
    const homeKm = typeof homeLat === 'number' && typeof homeLng === 'number'
      ? distanceMeters(homeLat, homeLng, place.latitude, place.longitude) / 1000
      : 0;
    const points = Math.round(rarityPoints(timesCheckedIn) * distanceMultiplier(homeKm));

    const now = FieldValue.serverTimestamp();
    tx.set(placeRef, {
      name: place.name,
      latitude: place.latitude,
      longitude: place.longitude,
      types: place.types,
      category: place.category,
      timesCheckedIn: FieldValue.increment(1),
    }, { merge: true });
    tx.set(lastCheckInRef, { lastCheckInAt: now });
    tx.set(checkInRef, {
      uid, placeId, placeName: place.name, points, distanceMeters: Math.round(distance), createdAt: now,
    });
    tx.update(userRef, { points: FieldValue.increment(points) });
    return points;
  });

  logger.info('Checked in', { uid, placeId, pointsEarned });
  return { pointsEarned, placeName: place.name };
});

// ---------------------------------------------------------------------------
// Business codes
//
// A restaurant, café or hotel can claim its place (requestBusinessClaim); the
// claim waits in businesses/{placeId} until approved with
// scripts/business-claims.js, which also creates the place's secret in
// businessSecrets/{placeId}. Clients can never read that collection.
//
// The owner's app shows a 6-digit code (getBusinessCode) that changes every
// BUSINESS_CODE_PERIOD_SECONDS, derived from the secret like an authenticator
// app code (RFC 6238), so no codes are stored. Customers give it at check-in.
// ---------------------------------------------------------------------------

const crypto = require('crypto');

const BUSINESS_CODE_PERIOD_SECONDS = 10 * 60;
const BUSINESS_CODE_DIGITS = 6;
const MAX_CODE_FAILURES = 5; // per user, per place, per lockout window
const CODE_LOCKOUT_MINUTES = 60;

function codeCounter(ms) {
  return Math.floor(ms / 1000 / BUSINESS_CODE_PERIOD_SECONDS);
}

function businessCodeAt(secret, counter) {
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(counter));
  const hmac = crypto.createHmac('sha1', Buffer.from(secret, 'base64')).update(message).digest();
  const offset = hmac[hmac.length - 1] & 0xf;
  const value = hmac.readUInt32BE(offset) & 0x7fffffff;
  return String(value % 10 ** BUSINESS_CODE_DIGITS).padStart(BUSINESS_CODE_DIGITS, '0');
}

async function readBusinessSecret(db, placeId) {
  const secretDoc = await db.collection('businessSecrets').doc(placeId).get();
  const secret = secretDoc.get('secret');
  if (!secret) {
    logger.error('Approved business has no secret', { placeId });
    throw new HttpsError('internal', 'This place\'s check-in code isn\'t set up yet. Please tell the staff.');
  }
  return secret;
}

/**
 * Throws unless the code is right for this place, when its business has been
 * approved; unclaimed places are location-only. The current and previous code
 * are accepted, in case it changed while the customer was typing. Wrong codes
 * are counted per user and place, and lock that place for CODE_LOCKOUT_MINUTES
 * after MAX_CODE_FAILURES.
 */
async function checkBusinessCode(db, uid, place, code) {
  const businessDoc = await db.collection('businesses').doc(place.id).get();
  if (!businessDoc.exists || businessDoc.get('status') !== 'approved') return;

  const typed = typeof code === 'string' ? code.replace(/\s/g, '') : '';
  if (!new RegExp(`^\\d{${BUSINESS_CODE_DIGITS}}$`).test(typed)) {
    throw new HttpsError('invalid-argument',
      `Enter the ${BUSINESS_CODE_DIGITS}-digit code from the staff at ${place.name}.`);
  }

  const secret = await readBusinessSecret(db, place.id);
  const attemptsRef = db.collection('users').doc(uid).collection('codeAttempts').doc(place.id);
  const lockoutMs = CODE_LOCKOUT_MINUTES * 60 * 1000;

  // In a transaction so simultaneous guesses are all counted.
  const result = await db.runTransaction(async (tx) => {
    const attempts = await tx.get(attemptsRef);
    const now = Date.now();
    const windowStart = attempts.exists ? attempts.get('windowStart')?.toMillis() ?? 0 : 0;
    const inWindow = now - windowStart < lockoutMs;
    const failures = inWindow ? attempts.get('failures') ?? 0 : 0;

    if (failures >= MAX_CODE_FAILURES) {
      return { locked: true, minutesLeft: Math.ceil((windowStart + lockoutMs - now) / 60000) };
    }

    const counter = codeCounter(now);
    const correct = [counter, counter - 1].some((c) =>
      crypto.timingSafeEqual(Buffer.from(businessCodeAt(secret, c)), Buffer.from(typed)));
    if (correct) return { correct: true };

    if (inWindow) {
      tx.update(attemptsRef, { failures: FieldValue.increment(1) });
    } else {
      tx.set(attemptsRef, { windowStart: FieldValue.serverTimestamp(), failures: 1 });
    }
    return { triesLeft: MAX_CODE_FAILURES - failures - 1 };
  });

  if (result.correct) return;
  logger.info('Wrong business code', { uid, placeId: place.id, result });
  if (result.locked || result.triesLeft === 0) {
    const minutes = result.minutesLeft ?? CODE_LOCKOUT_MINUTES;
    throw new HttpsError('resource-exhausted',
      `Too many wrong codes for ${place.name}. Try again in ${minutes} minute${minutes === 1 ? '' : 's'}.`);
  }
  throw new HttpsError('invalid-argument',
    `That code isn't right. ${result.triesLeft} ${result.triesLeft === 1 ? 'try' : 'tries'} left.`);
}

/** Asks to manage a restaurant, café or hotel. Approved by an admin. */
exports.requestBusinessClaim = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to register your business.');
  }
  const placeId = readPlaceId(request.data?.placeId);
  const place = toPlace(await placesRequest(`places/${placeId}`, { fieldMask: PLACE_FIELDS.join(',') }));
  if (!BUSINESS_CATEGORIES.includes(place.category)) {
    throw new HttpsError('failed-precondition', 'Only restaurants, cafés and hotels can be registered.');
  }

  const db = getFirestore();
  const userRef = db.collection('users').doc(uid);
  const businessRef = db.collection('businesses').doc(placeId);

  const status = await db.runTransaction(async (tx) => {
    const [userDoc, businessDoc] = await Promise.all([tx.get(userRef), tx.get(businessRef)]);
    if (!userDoc.exists || userDoc.get('phoneVerified') !== true) {
      throw new HttpsError('failed-precondition', 'Verify your phone number before registering a business.');
    }

    const current = businessDoc.exists ? businessDoc.get('status') : null;
    const ownedByCaller = businessDoc.exists && businessDoc.get('ownerUid') === uid;
    if (current === 'approved' || current === 'pending') {
      if (ownedByCaller) return current;
      throw new HttpsError('already-exists', `${place.name} has already been registered by someone else.`);
    }

    // New, or a rejected claim that anyone may try again.
    tx.set(businessRef, {
      ownerUid: uid,
      status: 'pending',
      placeName: place.name,
      category: place.category,
      requestedAt: FieldValue.serverTimestamp(),
    });
    return 'pending';
  });

  logger.info('requestBusinessClaim', { uid, placeId, place: place.name, status });
  return { status };
});

/** Returns the current check-in code for a place the caller manages. */
exports.getBusinessCode = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to see your business code.');
  }
  const placeId = readPlaceId(request.data?.placeId);

  const db = getFirestore();
  const businessDoc = await db.collection('businesses').doc(placeId).get();
  if (!businessDoc.exists || businessDoc.get('ownerUid') !== uid) {
    throw new HttpsError('permission-denied', 'You don\'t manage this place.');
  }
  if (businessDoc.get('status') !== 'approved') {
    throw new HttpsError('failed-precondition', 'Your registration hasn\'t been approved yet.');
  }

  const secret = await readBusinessSecret(db, placeId);
  const counter = codeCounter(Date.now());
  return {
    code: businessCodeAt(secret, counter),
    expiresAt: (counter + 1) * BUSINESS_CODE_PERIOD_SECONDS * 1000,
    placeName: businessDoc.get('placeName'),
  };
});

// ---------------------------------------------------------------------------
// Buddy check-ins
//
// Two friends who check in at the same place within BUDDY_WINDOW_MINUTES of
// each other, and each name the other, both earn BUDDY_BONUS_POINTS.
//
// Each request is stored at buddyCheckins/{placeId}_{initiatorUid}_{selectedUid},
// so the friend's matching request is a single document read inside the
// transaction (no composite index, and two simultaneous calls can't both pay
// out or both miss each other).
// ---------------------------------------------------------------------------

const BUDDY_WINDOW_MINUTES = 5; // keep in sync with the message in MapScreen
const BUDDY_BONUS_POINTS = 50;

function buddyDocId(placeId, initiatorUid, selectedUid) {
  return `${placeId}_${initiatorUid}_${selectedUid}`;
}

/**
 * Pairs the caller's check-in at a place with a friend's.
 *
 * The caller must have checked in at the place (via performCheckIn) within the
 * last BUDDY_WINDOW_MINUTES, which is what proves they're actually there. If
 * the friend already named the caller at the same place within the window,
 * both get the bonus; otherwise the caller's request waits for the friend.
 */
exports.attemptBuddyCheckIn = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to check in with a buddy.');
  }
  const placeId = request.data?.locationId;
  if (typeof placeId !== 'string' || !/^[A-Za-z0-9_-]{1,300}$/.test(placeId)) {
    throw new HttpsError('invalid-argument', 'A valid place is required.');
  }
  const rawUsername = request.data?.friendUsername;
  const friendUsername = typeof rawUsername === 'string'
    ? rawUsername.trim().replace(/^@/, '').toLowerCase()
    : '';
  if (!friendUsername) {
    throw new HttpsError('invalid-argument', 'Enter your friend\'s username.');
  }

  const db = getFirestore();
  const friends = await db.collection('users').where('username', '==', friendUsername).limit(1).get();
  if (friends.empty) {
    throw new HttpsError('not-found', `No user found with the username @${friendUsername}.`);
  }
  const friendUid = friends.docs[0].id;
  if (friendUid === uid) {
    throw new HttpsError('invalid-argument', 'You can\'t buddy check-in with yourself.');
  }

  const userRef = db.collection('users').doc(uid);
  const friendRef = db.collection('users').doc(friendUid);
  const lastCheckInRef = userRef.collection('placeCheckIns').doc(placeId);
  const mineRef = db.collection('buddyCheckins').doc(buddyDocId(placeId, uid, friendUid));
  const theirsRef = db.collection('buddyCheckins').doc(buddyDocId(placeId, friendUid, uid));
  const windowMs = BUDDY_WINDOW_MINUTES * 60 * 1000;

  const matched = await db.runTransaction(async (tx) => {
    const [userDoc, lastDoc, mineDoc, theirsDoc] = await Promise.all([
      tx.get(userRef), tx.get(lastCheckInRef), tx.get(mineRef), tx.get(theirsRef),
    ]);
    const now = Date.now();

    if (!userDoc.exists || userDoc.get('phoneVerified') !== true) {
      throw new HttpsError('failed-precondition', 'Verify your phone number before checking in.');
    }

    const checkedInAt = lastDoc.exists ? lastDoc.get('lastCheckInAt')?.toMillis() : null;
    if (!checkedInAt || now - checkedInAt > windowMs) {
      throw new HttpsError('failed-precondition',
        `Check in at this place first - buddy check-ins only work within ${BUDDY_WINDOW_MINUTES} minutes of checking in.`);
    }

    // A confirmed pairing for this check-in has already paid out.
    const mineConfirmedAt = mineDoc.exists && mineDoc.get('status') === 'confirmed'
      ? mineDoc.get('confirmedAt')?.toMillis()
      : null;
    if (mineConfirmedAt && mineConfirmedAt >= checkedInAt) {
      throw new HttpsError('already-exists', 'You\'ve already earned the buddy bonus with this friend here.');
    }

    const theirsAt = theirsDoc.exists && theirsDoc.get('status') === 'pending'
      ? theirsDoc.get('createdAt')?.toMillis()
      : null;
    const serverNow = FieldValue.serverTimestamp();

    if (theirsAt && now - theirsAt <= windowMs) {
      const confirmed = { status: 'confirmed', confirmedAt: serverNow };
      tx.update(theirsRef, confirmed);
      tx.set(mineRef, {
        placeId, initiatorId: uid, selectedUserId: friendUid, createdAt: serverNow, ...confirmed,
      });
      tx.update(userRef, { points: FieldValue.increment(BUDDY_BONUS_POINTS) });
      tx.update(friendRef, { points: FieldValue.increment(BUDDY_BONUS_POINTS) });
      return true;
    }

    // No match yet: (re)start the caller's request so the friend can match it.
    tx.set(mineRef, {
      placeId, initiatorId: uid, selectedUserId: friendUid, status: 'pending', createdAt: serverNow,
    });
    return false;
  });

  logger.info('attemptBuddyCheckIn', { uid, friendUid, placeId, matched });
  return { matched, bonusPoints: matched ? BUDDY_BONUS_POINTS : 0 };
});
