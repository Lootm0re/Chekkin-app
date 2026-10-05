const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { isDeepStrictEqual } = require('util');
const logger = require('firebase-functions/logger');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');

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
// location). The fields other users may see - for the leaderboard, friends
// and group check-ins - are mirrored to publicProfiles/{uid}, which only this
// function writes. A user who hides their picture gets no photo or avatar
// there, so others see the default icon. Points stay authoritative on
// users/{uid}; the copy follows within a few seconds.
// ---------------------------------------------------------------------------

const PUBLIC_PROFILE_FIELDS = ['name', 'username', 'points'];

// Same as PropertyCategoryIds in the avatar_maker package. Each avatar part is
// stored as the chosen item's id, e.g. 'HairStyles/Long'.
const AVATAR_PARTS = [
  'Accessory', 'AvatarBackground', 'AvatarEffect', 'AvatarEffectColor', 'Background',
  'EyebrowType', 'EyeType', 'FacialHairColor', 'FacialHairType', 'HairColor', 'HairStyle',
  'MouthType', 'Nose', 'OutfitColor', 'OutfitType', 'SkinColor',
];

function cleanAvatar(avatar) {
  if (!avatar || typeof avatar !== 'object') return undefined;
  const clean = {};
  for (const part of AVATAR_PARTS) {
    const item = avatar[part];
    if (typeof item === 'string' && /^[A-Za-z0-9_/]{1,64}$/.test(item)) clean[part] = item;
  }
  return Object.keys(clean).length ? clean : undefined;
}

function publicProfileOf(userData) {
  const profile = {};
  for (const field of PUBLIC_PROFILE_FIELDS) {
    if (userData[field] !== undefined) profile[field] = userData[field];
  }
  // The photo and avatar are shown unless the user has hidden them.
  // profileImage says which to show when both exist: 'avatar' or 'photo'.
  if (userData.avatarHidden !== true) {
    const avatar = cleanAvatar(userData.avatar);
    if (avatar) profile.avatar = avatar;
    if (typeof userData.profilePictureUrl === 'string') profile.profilePictureUrl = userData.profilePictureUrl;
    if (['avatar', 'photo'].includes(userData.profileImage)) profile.profileImage = userData.profileImage;
  }
  return profile;
}

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
    isDeepStrictEqual(publicProfileOf(before.data()), profile);
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

function throwIfCheckedInRecently(lastCheckInDoc, place) {
  const lastAt = lastCheckInDoc.exists ? lastCheckInDoc.get('lastCheckInAt')?.toMillis() : null;
  if (lastAt && Date.now() - lastAt < CHECK_IN_COOLDOWN_HOURS * 3600 * 1000) {
    throw new HttpsError('already-exists',
      `You've already checked in at ${place.name} today. Try again tomorrow.`);
  }
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

// Group check-ins: at a registered business, the customer who uses the code
// can invite up to GROUP_MAX_SIZE - 1 friends. Each friend joins from their
// own phone (joinGroup) within GROUP_WINDOW_MINUTES, at the place. Everyone's
// base points are multiplied by GROUP_MULTIPLIERS for the group's size, and
// members are topped up as each friend joins.
const GROUP_MAX_SIZE = 6;
const GROUP_WINDOW_MINUTES = 10;
const GROUP_MULTIPLIERS = { 1: 1, 2: 1.5, 3: 2, 4: 3, 5: 3.5, 6: 5 };

/** Points for this user at this place: rarity times distance from home. */
function basePoints(userDoc, place, timesCheckedIn) {
  const homeLat = userDoc.get('homeLatitude');
  const homeLng = userDoc.get('homeLongitude');
  const homeKm = typeof homeLat === 'number' && typeof homeLng === 'number'
    ? distanceMeters(homeLat, homeLng, place.latitude, place.longitude) / 1000
    : 0;
  return Math.round(rarityPoints(timesCheckedIn) * distanceMultiplier(homeKm));
}

function readUid(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9]{1,128}$/.test(value)) {
    throw new HttpsError('invalid-argument', 'A valid user is required.');
  }
  return value;
}

/** The friends to invite to a group check-in; they must be on the caller's friends list. */
async function readGroupFriends(db, uid, value) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.length > GROUP_MAX_SIZE - 1) {
    throw new HttpsError('invalid-argument', `Pick up to ${GROUP_MAX_SIZE - 1} friends.`);
  }
  const friendUids = [...new Set(value.map(readUid))].filter((f) => f !== uid);
  if (friendUids.length === 0) return [];
  const friendDocs = await db.getAll(...friendUids.map((f) => db.doc(`users/${uid}/friends/${f}`)));
  if (friendDocs.some((d) => !d.exists)) {
    throw new HttpsError('failed-precondition', 'You can only check in with people on your friends list.');
  }
  return friendUids;
}

/**
 * Checks the caller in at a place and awards points.
 *
 * The place's location and types come from the Places API, not the client.
 * The caller must be within CHECK_IN_RANGE_METERS of it and can check in at
 * the same place once every CHECK_IN_COOLDOWN_HOURS. At a restaurant, café or
 * hotel whose business has registered, the caller must also give the
 * business's current code, which then can't be used again, and may invite
 * friends (friendUids) to join as a group.
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
  const userRef = db.collection('users').doc(uid);
  const placeRef = db.collection('places').doc(placeId);
  const lastCheckInRef = db.collection('users').doc(uid).collection('placeCheckIns').doc(placeId);
  const checkInRef = db.collection('checkIns').doc();

  const requiresCode = BUSINESS_CATEGORIES.includes(place.category) &&
    (await db.collection('businesses').doc(placeId).get()).get('status') === 'approved';
  const friendUids = await readGroupFriends(db, uid, request.data?.friendUids);
  if (friendUids.length > 0 && !requiresCode) {
    throw new HttpsError('failed-precondition',
      'Group check-ins are only available at registered restaurants, cafés and hotels.');
  }

  if (requiresCode) {
    // Checked first so a code can't be used up, or count as a wrong guess,
    // when the check-in would be refused anyway. The transaction below
    // checks again.
    throwIfCheckedInRecently(await lastCheckInRef.get(), place);
    await useBusinessCode(db, uid, place, request.data?.code);
  }

  const groupRef = friendUids.length > 0 ? db.collection('groups').doc() : null;

  const pointsEarned = await db.runTransaction(async (tx) => {
    const [userDoc, placeDoc, lastDoc] = await Promise.all([
      tx.get(userRef), tx.get(placeRef), tx.get(lastCheckInRef),
    ]);

    if (!userDoc.exists || userDoc.get('phoneVerified') !== true) {
      throw new HttpsError('failed-precondition', 'Verify your phone number before checking in.');
    }

    throwIfCheckedInRecently(lastDoc, place);

    const timesCheckedIn = placeDoc.exists ? (placeDoc.get('timesCheckedIn') ?? 0) : 0;
    const points = basePoints(userDoc, place, timesCheckedIn);

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
      ...(groupRef ? { groupId: groupRef.id } : {}),
    });
    tx.update(userRef, { points: FieldValue.increment(points) });

    if (groupRef) {
      const expiresAt = Timestamp.fromMillis(Date.now() + GROUP_WINDOW_MINUTES * 60 * 1000);
      tx.set(groupRef, {
        placeId,
        placeName: place.name,
        latitude: place.latitude,
        longitude: place.longitude,
        primaryUid: uid,
        members: [uid],
        invited: friendUids,
        // Everyone's base points use the place's rarity when the group started.
        rarityCount: timesCheckedIn,
        basePoints: { [uid]: points },
        awarded: { [uid]: points },
        size: 1,
        status: 'open',
        createdAt: now,
        expiresAt,
      });
      for (const friendUid of friendUids) {
        tx.set(db.doc(`users/${friendUid}/groupInvites/${groupRef.id}`), {
          placeId,
          placeName: place.name,
          fromUid: uid,
          fromName: userDoc.get('name') ?? '',
          fromUsername: userDoc.get('username') ?? '',
          expiresAt,
        });
      }
    }
    return points;
  });

  logger.info('Checked in', { uid, placeId, pointsEarned, groupId: groupRef?.id, invited: friendUids.length });
  return {
    pointsEarned,
    placeName: place.name,
    groupId: groupRef?.id ?? null,
    invited: friendUids.length,
    groupWindowMinutes: GROUP_WINDOW_MINUTES,
  };
});

/**
 * Joins a group check-in the caller was invited to. The caller must be at the
 * place, and hasn't checked in there in the last CHECK_IN_COOLDOWN_HOURS;
 * joining counts as their check-in. Everyone in the group, including the
 * caller, is brought up to their base points times the new size's multiplier.
 */
exports.joinGroup = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to join a group check-in.');
  }
  const groupId = request.data?.groupId;
  if (typeof groupId !== 'string' || !/^[A-Za-z0-9]{1,64}$/.test(groupId)) {
    throw new HttpsError('invalid-argument', 'A valid group is required.');
  }
  const device = readCoordinates(request.data, 'deviceLatitude', 'deviceLongitude');

  const db = getFirestore();
  const groupRef = db.collection('groups').doc(groupId);
  const inviteRef = db.doc(`users/${uid}/groupInvites/${groupId}`);
  const first = await groupRef.get();
  if (!first.exists) {
    throw new HttpsError('not-found', 'That group check-in no longer exists.');
  }
  const place = {
    id: first.get('placeId'),
    name: first.get('placeName'),
    latitude: first.get('latitude'),
    longitude: first.get('longitude'),
  };
  const distance = distanceMeters(device.lat, device.lng, place.latitude, place.longitude);
  logger.info('joinGroup', { uid, groupId, placeId: place.id, distance: Math.round(distance) });
  if (distance > CHECK_IN_RANGE_METERS) {
    throw new HttpsError('failed-precondition',
      `Too far away - get within ${CHECK_IN_RANGE_METERS}m of ${place.name} to join ` +
      `(currently ${Math.round(distance)}m away).`);
  }

  const userRef = db.collection('users').doc(uid);
  const lastCheckInRef = userRef.collection('placeCheckIns').doc(place.id);
  const placeRef = db.collection('places').doc(place.id);
  const businessRef = db.collection('businesses').doc(place.id);
  const checkInRef = db.collection('checkIns').doc();

  const result = await db.runTransaction(async (tx) => {
    const [groupDoc, userDoc, lastDoc] = await Promise.all([
      tx.get(groupRef), tx.get(userRef), tx.get(lastCheckInRef),
    ]);
    const group = groupDoc.data();
    const members = group.members ?? [];

    if (!(group.invited ?? []).includes(uid)) {
      throw new HttpsError('permission-denied', 'You weren\'t invited to this group check-in.');
    }
    if (members.includes(uid)) {
      throw new HttpsError('already-exists', 'You\'re already in this group.');
    }
    if (group.status !== 'open' || members.length >= GROUP_MAX_SIZE) {
      throw new HttpsError('failed-precondition', 'This group is full.');
    }
    if (Date.now() > group.expiresAt.toMillis()) {
      throw new HttpsError('deadline-exceeded', 'This group check-in has closed.');
    }
    if (!userDoc.exists || userDoc.get('phoneVerified') !== true) {
      throw new HttpsError('failed-precondition', 'Verify your phone number before checking in.');
    }
    throwIfCheckedInRecently(lastDoc, place);

    const newMembers = [...members, uid];
    const size = newMembers.length;
    const multiplier = GROUP_MULTIPLIERS[size];
    const myBase = basePoints(userDoc, place, group.rarityCount ?? 0);
    const base = { ...group.basePoints, [uid]: myBase };
    const awarded = { ...group.awarded };
    for (const member of newMembers) {
      const target = Math.round(base[member] * multiplier);
      const topUp = target - (awarded[member] ?? 0);
      if (topUp !== 0) {
        tx.update(db.collection('users').doc(member), { points: FieldValue.increment(topUp) });
      }
      awarded[member] = target;
    }

    const full = size >= GROUP_MAX_SIZE;
    tx.update(groupRef, { members: newMembers, basePoints: base, awarded, size, status: full ? 'full' : 'open' });

    const now = FieldValue.serverTimestamp();
    tx.set(lastCheckInRef, { lastCheckInAt: now });
    tx.set(checkInRef, {
      uid, placeId: place.id, placeName: place.name, points: myBase, groupId,
      distanceMeters: Math.round(distance), createdAt: now,
    });
    tx.set(placeRef, { timesCheckedIn: FieldValue.increment(1) }, { merge: true });
    // For the owner's stats: a group counts once it has two people.
    tx.set(businessRef, size === 2
      ? { groupCount: FieldValue.increment(1), groupMembers: FieldValue.increment(2) }
      : { groupMembers: FieldValue.increment(1) }, { merge: true });

    tx.delete(inviteRef);
    if (full) {
      for (const invited of group.invited.filter((f) => !newMembers.includes(f))) {
        tx.delete(db.doc(`users/${invited}/groupInvites/${groupId}`));
      }
    }
    return { pointsEarned: awarded[uid], groupSize: size, multiplier };
  });

  logger.info('Joined group', { uid, groupId, ...result });
  return { ...result, placeName: place.name };
});

// ---------------------------------------------------------------------------
// Business codes
//
// A restaurant, café or hotel can claim its place (requestBusinessClaim); the
// claim waits in businesses/{placeId} until approved with
// scripts/business-claims.js, which also creates the place's secret in
// businessSecrets/{placeId}. Clients can never read that collection.
//
// The owner's app shows a 6-digit code (getBusinessCode). Each code works for
// one customer: once used, the next code in the sequence takes its place.
// Codes are derived from the secret and a sequence number (RFC 4226 HOTP), so
// no codes are stored. An unused code expires after
// BUSINESS_CODE_LIFETIME_MINUTES, and the owner can retire it early
// (newBusinessCode). businesses/{placeId}.codeSeq changes whenever the code
// does, so the owner's screen knows to fetch the new one.
// ---------------------------------------------------------------------------

const crypto = require('crypto');

const BUSINESS_CODE_DIGITS = 6;
const BUSINESS_CODE_LIFETIME_MINUTES = 10;
// An expired (not used or retired) code still works this long after expiry,
// in case it changed while the customer was typing.
const CODE_GRACE_SECONDS = 60;
const MAX_CODE_FAILURES = 5; // per user, per place, per lockout window
const CODE_LOCKOUT_MINUTES = 60;

function businessCodeAt(secret, counter) {
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(counter));
  const hmac = crypto.createHmac('sha1', Buffer.from(secret, 'base64')).update(message).digest();
  const offset = hmac[hmac.length - 1] & 0xf;
  const value = hmac.readUInt32BE(offset) & 0x7fffffff;
  return String(value % 10 ** BUSINESS_CODE_DIGITS).padStart(BUSINESS_CODE_DIGITS, '0');
}

function codesMatch(a, b) {
  return a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

function readSecret(secretDoc, placeId) {
  const secret = secretDoc.get('secret');
  if (!secret) {
    logger.error('Approved business has no secret', { placeId });
    throw new HttpsError('internal', 'This place\'s check-in code isn\'t set up yet. Please tell the staff.');
  }
  return secret;
}

/**
 * Returns the place's current code, starting a new one if it has expired or
 * [retire] is set. Retiring (the owner's "New code") gives no grace period.
 */
async function currentBusinessCode(db, placeId, { retire = false } = {}) {
  const secretRef = db.collection('businessSecrets').doc(placeId);
  const businessRef = db.collection('businesses').doc(placeId);
  const lifetimeMs = BUSINESS_CODE_LIFETIME_MINUTES * 60 * 1000;

  return db.runTransaction(async (tx) => {
    const secretDoc = await tx.get(secretRef);
    const secret = readSecret(secretDoc, placeId);
    const now = Date.now();
    let seq = secretDoc.get('seq') ?? 0;
    let issuedAt = secretDoc.get('issuedAt')?.toMillis() ?? null;

    if (retire || issuedAt === null || now - issuedAt >= lifetimeMs) {
      const expiredUnused = !retire && issuedAt !== null;
      seq += 1;
      issuedAt = now;
      tx.update(secretRef, {
        seq,
        issuedAt: Timestamp.fromMillis(now),
        graceSeq: expiredUnused ? seq - 1 : null,
        graceUntil: expiredUnused
          ? Timestamp.fromMillis(secretDoc.get('issuedAt').toMillis() + lifetimeMs + CODE_GRACE_SECONDS * 1000)
          : null,
      });
      tx.update(businessRef, { codeSeq: seq });
    }
    return { code: businessCodeAt(secret, seq), expiresAt: issuedAt + lifetimeMs, seq };
  });
}

/**
 * Throws unless [code] is the place's current code (or an expired one still
 * in its grace period), and uses it up. Wrong codes are counted per user and
 * place, and lock that place for CODE_LOCKOUT_MINUTES after
 * MAX_CODE_FAILURES.
 */
async function useBusinessCode(db, uid, place, code) {
  const typed = typeof code === 'string' ? code.replace(/\s/g, '') : '';
  if (!new RegExp(`^\\d{${BUSINESS_CODE_DIGITS}}$`).test(typed)) {
    throw new HttpsError('invalid-argument',
      `Enter the ${BUSINESS_CODE_DIGITS}-digit code from the staff at ${place.name}.`);
  }

  const secretRef = db.collection('businessSecrets').doc(place.id);
  const businessRef = db.collection('businesses').doc(place.id);
  const attemptsRef = db.collection('users').doc(uid).collection('codeAttempts').doc(place.id);
  const lockoutMs = CODE_LOCKOUT_MINUTES * 60 * 1000;
  const lifetimeMs = BUSINESS_CODE_LIFETIME_MINUTES * 60 * 1000;

  // In a transaction so simultaneous guesses are all counted, and two
  // customers can't both use the same code.
  const result = await db.runTransaction(async (tx) => {
    const [attempts, secretDoc] = await Promise.all([tx.get(attemptsRef), tx.get(secretRef)]);
    const secret = readSecret(secretDoc, place.id);
    const now = Date.now();
    const windowStart = attempts.exists ? attempts.get('windowStart')?.toMillis() ?? 0 : 0;
    const inWindow = now - windowStart < lockoutMs;
    const failures = inWindow ? attempts.get('failures') ?? 0 : 0;

    if (failures >= MAX_CODE_FAILURES) {
      return { locked: true, minutesLeft: Math.ceil((windowStart + lockoutMs - now) / 60000) };
    }

    const seq = secretDoc.get('seq') ?? 0;
    const issuedAt = secretDoc.get('issuedAt')?.toMillis() ?? null;
    const graceSeq = secretDoc.get('graceSeq');
    const graceUntil = secretDoc.get('graceUntil')?.toMillis() ?? 0;

    if (issuedAt !== null && now - issuedAt < lifetimeMs && codesMatch(businessCodeAt(secret, seq), typed)) {
      // Used: the next code replaces it.
      tx.update(secretRef, { seq: seq + 1, issuedAt: Timestamp.fromMillis(now), graceSeq: null, graceUntil: null });
      tx.update(businessRef, { codeSeq: seq + 1 });
      return { correct: true };
    }
    if (typeof graceSeq === 'number' && now < graceUntil && codesMatch(businessCodeAt(secret, graceSeq), typed)) {
      tx.update(secretRef, { graceSeq: null, graceUntil: null });
      return { correct: true };
    }

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
    `That code isn't right or has already been used. ${result.triesLeft} ${result.triesLeft === 1 ? 'try' : 'tries'} left.`);
}

/** Throws unless the caller manages this approved business; returns its document. */
async function readOwnBusiness(db, uid, placeId) {
  const businessDoc = await db.collection('businesses').doc(placeId).get();
  if (!businessDoc.exists || businessDoc.get('ownerUid') !== uid) {
    throw new HttpsError('permission-denied', 'You don\'t manage this place.');
  }
  if (businessDoc.get('status') !== 'approved') {
    throw new HttpsError('failed-precondition', 'Your registration hasn\'t been approved yet.');
  }
  return businessDoc;
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
  const businessDoc = await readOwnBusiness(db, uid, placeId);
  const { code, expiresAt, seq } = await currentBusinessCode(db, placeId);
  return { code, expiresAt, seq, placeName: businessDoc.get('placeName') };
});

/** Retires the current code at once (e.g. if it was seen by someone else) and returns a new one. */
exports.newBusinessCode = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to manage your business.');
  }
  const placeId = readPlaceId(request.data?.placeId);
  const db = getFirestore();
  const businessDoc = await readOwnBusiness(db, uid, placeId);
  const { code, expiresAt, seq } = await currentBusinessCode(db, placeId, { retire: true });
  logger.info('newBusinessCode', { uid, placeId, seq });
  return { code, expiresAt, seq, placeName: businessDoc.get('placeName') };
});

/**
 * Check-in counts for a place the caller manages: since the start of the
 * owner's day (todayStart, sent by the app since it knows the time zone), the
 * last 7 days, and since approval, plus group check-ins. Counts only - owners
 * never see who checked in.
 */
exports.getBusinessStats = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to see your business stats.');
  }
  const placeId = readPlaceId(request.data?.placeId);
  const db = getFirestore();
  const businessDoc = await readOwnBusiness(db, uid, placeId);

  const now = Date.now();
  const dayMs = 24 * 3600 * 1000;
  let todayStart = request.data?.todayStart;
  if (typeof todayStart !== 'number' || todayStart > now || todayStart < now - 2 * dayMs) {
    todayStart = now - dayMs;
  }
  const approvedAt = businessDoc.get('approvedAt')?.toMillis() ?? businessDoc.get('requestedAt')?.toMillis() ?? 0;

  const countSince = async (ms) => (await db.collection('checkIns')
    .where('placeId', '==', placeId)
    .where('createdAt', '>=', Timestamp.fromMillis(ms))
    .count().get()).data().count;
  const [today, week, sinceApproval] = await Promise.all([
    countSince(Math.max(todayStart, approvedAt)),
    countSince(Math.max(now - 7 * dayMs, approvedAt)),
    countSince(approvedAt),
  ]);

  const groupCount = businessDoc.get('groupCount') ?? 0;
  const groupMembers = businessDoc.get('groupMembers') ?? 0;
  return {
    today,
    week,
    sinceApproval,
    groupCheckIns: groupCount,
    averageGroupSize: groupCount ? Math.round((groupMembers / groupCount) * 10) / 10 : null,
  };
});

// ---------------------------------------------------------------------------
// Friends
//
// Friendships are mutual: sendFriendRequest creates
// friendRequests/{fromUid}_{toUid}, and acceptFriendRequest turns it into
// users/{uid}/friends/{friendUid} on both sides. Only friends can be invited
// to group check-ins. Either person may delete a request (decline or cancel)
// directly; everything else is written here.
// ---------------------------------------------------------------------------

const MAX_FRIENDS = 200;

async function requireVerifiedUser(tx, userRef, action) {
  const userDoc = await tx.get(userRef);
  if (!userDoc.exists || userDoc.get('phoneVerified') !== true) {
    throw new HttpsError('failed-precondition', `Verify your phone number before ${action}.`);
  }
  return userDoc;
}

function makeFriends(tx, db, a, b) {
  const since = FieldValue.serverTimestamp();
  tx.set(db.doc(`users/${a}/friends/${b}`), { since });
  tx.set(db.doc(`users/${b}/friends/${a}`), { since });
  tx.delete(db.doc(`friendRequests/${a}_${b}`));
  tx.delete(db.doc(`friendRequests/${b}_${a}`));
}

/** Sends a friend request by username, or accepts theirs if they already asked. */
exports.sendFriendRequest = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to add friends.');
  }
  const raw = request.data?.username;
  const username = typeof raw === 'string' ? raw.trim().replace(/^@/, '').toLowerCase() : '';
  if (!username) {
    throw new HttpsError('invalid-argument', 'Enter your friend\'s username.');
  }

  const db = getFirestore();
  const found = await db.collection('users').where('username', '==', username).limit(1).get();
  if (found.empty) {
    throw new HttpsError('not-found', `No user found with the username @${username}.`);
  }
  const friendUid = found.docs[0].id;
  if (friendUid === uid) {
    throw new HttpsError('invalid-argument', 'You can\'t add yourself as a friend.');
  }

  const userRef = db.collection('users').doc(uid);
  const status = await db.runTransaction(async (tx) => {
    const [friendDoc, theirRequest, friendCount] = await Promise.all([
      tx.get(db.doc(`users/${uid}/friends/${friendUid}`)),
      tx.get(db.doc(`friendRequests/${friendUid}_${uid}`)),
      tx.get(userRef.collection('friends').count()),
    ]);
    const userDoc = await requireVerifiedUser(tx, userRef, 'adding friends');
    if (friendDoc.exists) {
      throw new HttpsError('already-exists', `You're already friends with @${username}.`);
    }
    if (friendCount.data().count >= MAX_FRIENDS) {
      throw new HttpsError('resource-exhausted', `You can have up to ${MAX_FRIENDS} friends.`);
    }
    if (theirRequest.exists) {
      makeFriends(tx, db, uid, friendUid);
      return 'friends';
    }
    tx.set(db.doc(`friendRequests/${uid}_${friendUid}`), {
      from: uid,
      to: friendUid,
      fromName: userDoc.get('name') ?? '',
      fromUsername: userDoc.get('username') ?? '',
      toName: found.docs[0].get('name') ?? '',
      toUsername: username,
      createdAt: FieldValue.serverTimestamp(),
    });
    return 'requested';
  });

  logger.info('sendFriendRequest', { uid, friendUid, status });
  return { status };
});

/** Accepts a friend request sent to the caller. */
exports.acceptFriendRequest = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to add friends.');
  }
  const fromUid = readUid(request.data?.fromUid);
  const db = getFirestore();
  const requestRef = db.doc(`friendRequests/${fromUid}_${uid}`);

  await db.runTransaction(async (tx) => {
    const requestDoc = await tx.get(requestRef);
    if (!requestDoc.exists) {
      throw new HttpsError('not-found', 'That friend request no longer exists.');
    }
    await requireVerifiedUser(tx, db.collection('users').doc(uid), 'adding friends');
    makeFriends(tx, db, uid, fromUid);
  });

  logger.info('acceptFriendRequest', { uid, fromUid });
  return { status: 'friends' };
});

/** Removes a friend, for both people. */
exports.removeFriend = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to manage friends.');
  }
  const friendUid = readUid(request.data?.friendUid);
  const db = getFirestore();
  const batch = db.batch();
  batch.delete(db.doc(`users/${uid}/friends/${friendUid}`));
  batch.delete(db.doc(`users/${friendUid}/friends/${uid}`));
  await batch.commit();
  logger.info('removeFriend', { uid, friendUid });
  return { status: 'removed' };
});
