const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onObjectFinalized } = require('firebase-functions/v2/storage');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { isDeepStrictEqual } = require('util');
const logger = require('firebase-functions/logger');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');
const crypto = require('crypto');

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
//
// Profile photos are stored at profile_pictures/{uid}.jpg, which Storage
// rules only let the owner read. Others load it through a download URL, which
// works without rules, so only these functions set it: publishProfilePicture
// puts a fresh one in users/{uid}.profilePictureUrl after each upload, and
// syncPublicProfile replaces its token when the user hides their picture, so
// URLs that were shown before stop working.
// ---------------------------------------------------------------------------

const PROFILE_PICTURE_PATH = /^profile_pictures\/([A-Za-z0-9]{1,128})\.jpg$/;

function profilePicturePath(uid) {
  return `profile_pictures/${uid}.jpg`;
}

function downloadUrlPrefix(bucketName, path) {
  return `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${encodeURIComponent(path)}?alt=media&token=`;
}

/** Gives the file a new download token, so old URLs stop working, and returns the new URL. */
async function replaceDownloadToken(file) {
  const token = crypto.randomUUID();
  await file.setMetadata({ metadata: { firebaseStorageDownloadTokens: token } });
  return downloadUrlPrefix(file.bucket.name, file.name) + token;
}

exports.publishProfilePicture = onObjectFinalized({ region: 'us-east1' }, async (event) => {
  const uid = PROFILE_PICTURE_PATH.exec(event.data.name)?.[1];
  if (!uid) return;
  const url = await replaceDownloadToken(getStorage().bucket(event.data.bucket).file(event.data.name));
  await getFirestore().collection('users').doc(uid).update({ profilePictureUrl: url });
  logger.info('Published profile picture', { uid });
});

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

function publicProfileOf(uid, userData) {
  const profile = {};
  for (const field of PUBLIC_PROFILE_FIELDS) {
    if (userData[field] !== undefined) profile[field] = userData[field];
  }
  // The photo and avatar are shown unless the user has hidden them.
  // profileImage says which to show when both exist: 'avatar' or 'photo'.
  if (userData.avatarHidden !== true) {
    const avatar = cleanAvatar(userData.avatar);
    if (avatar) profile.avatar = avatar;
    // Only a URL for the user's own photo, as publishProfilePicture sets it.
    const url = userData.profilePictureUrl;
    if (typeof url === 'string' &&
        url.startsWith(downloadUrlPrefix(getStorage().bucket().name, profilePicturePath(uid)))) {
      profile.profilePictureUrl = url;
    }
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

  const uid = event.params.uid;
  const before = event.data.before;

  // Hiding the picture: retire the photo URL others may have seen. The new
  // one goes back to users/{uid}, for the owner, which runs this again.
  const justHidden = after.get('avatarHidden') === true && before?.get('avatarHidden') !== true;
  // A failure here mustn't stop the public profile from hiding the picture.
  if (justHidden && typeof after.get('profilePictureUrl') === 'string') {
    try {
      const url = await replaceDownloadToken(getStorage().bucket().file(profilePicturePath(uid)));
      await after.ref.update({ profilePictureUrl: url });
      logger.info('Replaced hidden profile picture URL', { uid });
    } catch (err) {
      logger.error('Replacing hidden profile picture URL failed', { uid, message: err.message });
    }
  }

  const profile = publicProfileOf(uid, after.data());
  const unchanged = before?.exists &&
    isDeepStrictEqual(publicProfileOf(uid, before.data()), profile);
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

const HOSPITALITY_TYPES = ['restaurant', 'cafe', 'coffee_shop', 'lodging', 'hotel'];
const SHOP_TYPES = [
  'store', 'shopping_mall', 'department_store', 'supermarket', 'clothing_store', 'shoe_store',
  'book_store', 'electronics_store', 'jewelry_store', 'gift_shop', 'furniture_store',
  'home_goods_store', 'sporting_goods_store', 'florist',
];
const TOURISTIC_TYPES = [
  'museum', 'tourist_attraction', 'park', 'natural_feature', 'zoo', 'art_gallery', 'stadium',
  'amusement_park', 'landmark', 'historical_landmark', 'place_of_worship', 'church',
  'mosque', 'synagogue', 'hindu_temple', 'library',
];
const ALLOWED_PLACE_TYPES = [...HOSPITALITY_TYPES, ...SHOP_TYPES, ...TOURISTIC_TYPES];
const BLOCKED_PLACE_TYPES = ['premise', 'subpremise', 'residential', 'street_address'];

// One search for everything, nearest first: it returns at most 20 places, so
// in busy areas farther ones are left out, but check-ins need you within
// CHECK_IN_RANGE_METERS, so the place you're at is always there. (Two searches
// showed more, for twice the cost. Results can't be cached instead: the
// Places terms only allow caching place IDs and coordinates.)
// searchNearby rejects types it can't filter by (natural_feature, landmark,
// place_of_worship, premise, ...); results are still checked against the full
// lists above.
const SEARCH_INCLUDED_TYPES = [
  'museum', 'tourist_attraction', 'park', 'zoo', 'art_gallery', 'stadium', 'amusement_park',
  'historical_landmark', 'church', 'mosque', 'synagogue', 'hindu_temple', 'library',
  'restaurant', 'cafe', 'coffee_shop', 'lodging', ...SHOP_TYPES,
];

const NEARBY_RADIUS_METERS = 500;
const CHECK_IN_RANGE_METERS = 22; // keep in sync with MapScreen.checkInRangeMeters
const CHECK_IN_COOLDOWN_HOURS = 24; // per user, per place
const MAX_CHECK_INS_PER_PLACE_PER_WEEK = 2; // per user, rolling 7 days
const WEEK_MS = 7 * 24 * 3600 * 1000;

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

// Restaurants, cafés, hotels and shops ('business' categories) can only be
// checked in to once they're partners (see Partners below); everything else
// ('touristic') is location-only. The primary type decides first, so a hotel
// with a restaurant counts as a hotel, and a museum with a café as touristic.
const BUSINESS_CATEGORIES = ['restaurant', 'cafe', 'hotel', 'shop'];

function categoryOfType(type) {
  if (type === 'lodging' || type === 'hotel' || type.endsWith('_hotel')) return 'hotel';
  if (type === 'cafe' || type === 'coffee_shop') return 'cafe';
  if (type === 'restaurant' || type.endsWith('_restaurant')) return 'restaurant';
  if (SHOP_TYPES.includes(type) || type.endsWith('_store')) return 'shop';
  return null;
}

function placeCategory(primaryType, types) {
  if (primaryType) {
    const category = categoryOfType(primaryType);
    if (category) return category;
    if (TOURISTIC_TYPES.includes(primaryType)) return 'touristic';
  }
  const hospitality = ['hotel', 'cafe', 'restaurant'].find((c) => types.some((t) => categoryOfType(t) === c));
  if (hospitality) return hospitality;
  // Attractions are often also tagged 'store' for their gift shop.
  const isAttraction = types.some((t) => TOURISTIC_TYPES.includes(t));
  if (!isAttraction && types.some((t) => categoryOfType(t) === 'shop')) return 'shop';
  return 'touristic';
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

function readCoordinates(data, latKey, lngKey) {
  const lat = data?.[latKey];
  const lng = data?.[lngKey];
  if (typeof lat !== 'number' || typeof lng !== 'number' ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    throw new HttpsError('invalid-argument', 'A valid location is required.');
  }
  return { lat, lng };
}

/**
 * The user's check-ins at a place in the last 7 days, in ms, oldest first.
 * users/{uid}/placeCheckIns/{placeId}.recent keeps the latest
 * MAX_CHECK_INS_PER_PLACE_PER_WEEK; documents from before it only have
 * lastCheckInAt.
 */
function recentCheckIns(lastCheckInDoc) {
  if (!lastCheckInDoc.exists) return [];
  const recent = lastCheckInDoc.get('recent') ?? [lastCheckInDoc.get('lastCheckInAt')];
  return recent.filter(Boolean).map((t) => t.toMillis())
    .filter((ms) => Date.now() - ms < WEEK_MS).sort((a, b) => a - b);
}

function throwIfCheckInLimitReached(lastCheckInDoc, place) {
  const recent = recentCheckIns(lastCheckInDoc);
  const lastAt = recent[recent.length - 1];
  if (lastAt && Date.now() - lastAt < CHECK_IN_COOLDOWN_HOURS * 3600 * 1000) {
    throw new HttpsError('already-exists',
      `You've already checked in at ${place.name} today. Try again tomorrow.`);
  }
  if (recent.length >= MAX_CHECK_INS_PER_PLACE_PER_WEEK) {
    throw new HttpsError('already-exists',
      `You've already checked in at ${place.name} ${MAX_CHECK_INS_PER_PLACE_PER_WEEK} times this week. ` +
      `Try again ${formatDay(recent[0] + WEEK_MS)}.`);
  }
}

/** The new placeCheckIns fields for a check-in now. Set with merge. */
function placeCheckInUpdate(lastCheckInDoc) {
  const recent = [...recentCheckIns(lastCheckInDoc), Date.now()].slice(-MAX_CHECK_INS_PER_PLACE_PER_WEEK);
  return { lastCheckInAt: FieldValue.serverTimestamp(), recent: recent.map((ms) => Timestamp.fromMillis(ms)) };
}

// ---------------------------------------------------------------------------
// Location checks
//
// The device position comes from the client, so it can always be faked;
// these checks make that harder. The app sends the fix's accuracy, when it was
// taken and whether the OS flagged it as mocked (Android, and iOS 15+ for
// software-simulated locations; web always says no). A check-in must also be reachable in time from the user's
// previous one (users/{uid}.lastCheckIn). Accounts listed in devTesters/{uid}
// (scripts/dev-testers.js) skip these checks, so DEV_TOOLS builds can check in
// from a pretend location.
//
// Check-ins only come from the iOS and Android apps: see throwUnlessFromApp.
// enforceAppCheck stays off so dev testers can call without a token.
// ---------------------------------------------------------------------------

const LOCATION_CALLABLE = { enforceAppCheck: false };

const MAX_FIX_ACCURACY_METERS = 50;
const MAX_FIX_AGE_SECONDS = 120;
const MAX_CLOCK_AHEAD_SECONDS = 60; // device clocks run a little fast

// Fastest believable travel between check-ins: 300 km/h (cars, trains) for
// the first 1000 km, then 1000 km/h (planes). Within NEARBY_TRAVEL_KM anything
// goes, so neighbouring places can be visited back to back.
const GROUND_KMH = 300;
const FLIGHT_KMH = 1000;
const FLIGHT_FROM_KM = 1000;
const NEARBY_TRAVEL_KM = 1;

function appCheckStatus(request) {
  return request.app ? 'verified' : 'missing';
}

// Firebase app IDs of the iOS and Android apps, whose App Check tokens are
// accepted by throwUnlessFromApp. Empty until the apps are registered in
// Firebase (flutterfire configure); add their IDs here then. The web app is
// left out on purpose: the product is app-only, and web builds are only for
// testing.
const MOBILE_APP_IDS = [];

/**
 * Throws unless the call comes from the iOS or Android app, proven by a valid
 * App Check token, or from a dev tester (devTesters/{uid}), who may use the
 * DEV_TOOLS web build. Returns whether the caller is a dev tester.
 */
async function throwUnlessFromApp(db, uid, request, action) {
  if (await isDevTester(db, uid)) return true;
  const appId = request.app?.appId ?? null;
  if (!MOBILE_APP_IDS.includes(appId)) {
    logger.warn('Refused call from outside the apps', { uid, action, appId, appCheck: appCheckStatus(request) });
    throw new HttpsError('permission-denied', 'This only works in the Chekkin app for iPhone and Android.');
  }
  return false;
}

function readDeviceFix(data) {
  const { lat, lng } = readCoordinates(data, 'deviceLatitude', 'deviceLongitude');
  const accuracy = data?.deviceAccuracy;
  const timestamp = data?.deviceTimestamp;
  const isMocked = data?.deviceIsMocked;
  if (typeof accuracy !== 'number' || !(accuracy >= 0) ||
      typeof timestamp !== 'number' || !Number.isFinite(timestamp) || typeof isMocked !== 'boolean') {
    throw new HttpsError('invalid-argument', 'Your location is missing details. Reload the app and try again.');
  }
  return { lat, lng, accuracy, timestamp, isMocked };
}

async function isDevTester(db, uid) {
  return (await db.collection('devTesters').doc(uid).get()).exists;
}

function throwIfUntrustedFix(fix) {
  if (fix.isMocked) {
    throw new HttpsError('failed-precondition',
      'Your device says this location is simulated. Turn off any mock location app and try again.');
  }
  if (fix.accuracy > MAX_FIX_ACCURACY_METERS) {
    throw new HttpsError('failed-precondition',
      `Your location is only accurate to ${Math.round(fix.accuracy)}m, too rough to tell if you're ` +
      'here. Try again outside or with Wi-Fi turned on.');
  }
  const ageSeconds = (Date.now() - fix.timestamp) / 1000;
  if (ageSeconds < -MAX_CLOCK_AHEAD_SECONDS) {
    throw new HttpsError('failed-precondition',
      'Your device\'s clock is wrong. Set it to update automatically and try again.');
  }
  if (ageSeconds > MAX_FIX_AGE_SECONDS) {
    throw new HttpsError('failed-precondition', 'Your location is out of date. Please try again.');
  }
}

function minTravelHours(km) {
  if (km <= FLIGHT_FROM_KM) return km / GROUND_KMH;
  return FLIGHT_FROM_KM / GROUND_KMH + (km - FLIGHT_FROM_KM) / FLIGHT_KMH;
}

function throwIfImpossibleTravel(userDoc, place) {
  const last = userDoc.get('lastCheckIn');
  if (!last?.at) return;
  const km = distanceMeters(last.latitude, last.longitude, place.latitude, place.longitude) / 1000;
  if (km <= NEARBY_TRAVEL_KM) return;
  const waitMs = last.at.toMillis() + minTravelHours(km) * 3600 * 1000 - Date.now();
  if (waitMs > 0) {
    const minutes = Math.ceil(waitMs / 60000);
    const wait = minutes < 60 ? `${minutes} min` : `${Math.ceil(minutes / 60)} h`;
    throw new HttpsError('failed-precondition',
      `You checked in at ${last.placeName}, ${Math.round(km)} km away, too recently to be here ` +
      `already. Try again in ${wait}.`);
  }
}

/** Where and when the user last checked in, for throwIfImpossibleTravel. */
function lastCheckInOf(place) {
  return {
    placeName: place.name,
    latitude: place.latitude,
    longitude: place.longitude,
    at: FieldValue.serverTimestamp(),
  };
}

// ---------------------------------------------------------------------------
// Partners
//
// A restaurant, café, hotel or shop is a partner once its claim is approved
// (scripts/business-claims.js) and it has a tier in businesses/{placeId}.tier
// (scripts/partner-tiers.js). Only partners can be checked in to, with the
// staff's code; other businesses show as grey pins. Touristic places need no
// partner and earn TOURISTIC_POINTS.
//
// Each tier has a monthly budget of check-ins at full points, counted in
// placeBudgets/{placeId}_{YYYY-MM} (every group member counts). Once it's used
// up, check-ins there earn TOURISTIC_POINTS until the month changes.
//
// Against farming: partner points per user per day are capped at
// DAILY_PARTNER_POINTS_CAP (after group multipliers; the check-in still
// counts, for less), check-ins per place per user are limited to
// MAX_CHECK_INS_PER_PLACE_PER_WEEK, two people can only be in a group at the
// same place once every GROUP_REPEAT_DAYS, and owners can't check in at their
// own place. Days and months follow TIME_ZONE.
// ---------------------------------------------------------------------------

const TIERS = {
  basic: { label: 'Basic', points: 25, monthlyBudget: 100 },
  premium: { label: 'Premium', points: 50, monthlyBudget: 500 },
  diamond: { label: 'Diamond', points: 100, monthlyBudget: null }, // unlimited
};
const TOURISTIC_POINTS = 5;
const DAILY_PARTNER_POINTS_CAP = 3 * TIERS.diamond.points;
const GROUP_REPEAT_DAYS = 7;
const TIME_ZONE = 'Europe/Stockholm';

/** 'YYYY-MM-DD' in TIME_ZONE. */
function dayKey(ms) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit' })
    .format(new Date(ms));
}

function monthKey(ms) {
  return dayKey(ms).slice(0, 7);
}

/** E.g. 'on Mon 13 Oct', for messages. */
function formatDay(ms) {
  return 'on ' + new Intl.DateTimeFormat('en-GB', { timeZone: TIME_ZONE, weekday: 'short', day: 'numeric', month: 'short' })
    .format(new Date(ms));
}

/** The place's tier if it's a partner, else null. */
function partnerTier(businessDoc) {
  if (!businessDoc?.exists || businessDoc.get('status') !== 'approved') return null;
  const tier = businessDoc.get('tier');
  return Object.hasOwn(TIERS, tier) ? tier : null;
}

function budgetRef(db, placeId) {
  return db.collection('placeBudgets').doc(`${placeId}_${monthKey(Date.now())}`);
}

function budgetUsedUp(tier, budgetDoc) {
  const budget = TIERS[tier].monthlyBudget;
  return budget !== null && (budgetDoc.exists ? budgetDoc.get('used') ?? 0 : 0) >= budget;
}

/** Base points before group multipliers. */
function checkInPoints(tier, budgetDoc) {
  if (!tier || budgetUsedUp(tier, budgetDoc)) return TOURISTIC_POINTS;
  return TIERS[tier].points;
}

/** Counts a check-in against the place's monthly budget. Unlimited tiers are counted too, for stats. */
function useBudget(tx, db, placeId) {
  tx.set(budgetRef(db, placeId), { placeId, month: monthKey(Date.now()), used: FieldValue.increment(1) }, { merge: true });
}

function partnerPointsLeftToday(userDoc) {
  const today = userDoc.get('partnerPointsToday');
  const used = today?.day === dayKey(Date.now()) ? today.points ?? 0 : 0;
  return Math.max(0, DAILY_PARTNER_POINTS_CAP - used);
}

/**
 * Gives a user up to [points] partner points, as far as today's cap allows.
 * Returns how many they got.
 */
function awardPartnerPoints(tx, userRef, userDoc, points) {
  const left = partnerPointsLeftToday(userDoc);
  const given = Math.min(points, left);
  if (given > 0) {
    tx.update(userRef, {
      points: FieldValue.increment(given),
      partnerPointsToday: { day: dayKey(Date.now()), points: DAILY_PARTNER_POINTS_CAP - left + given },
    });
  }
  return given;
}

function throwIfOwnPlace(businessDoc, uid, place) {
  if (businessDoc?.exists && businessDoc.get('ownerUid') === uid) {
    throw new HttpsError('permission-denied', `You can't check in at ${place.name}, since you manage it.`);
  }
}

/** Members of [others] that [lastCheckInDoc]'s user was in a group with at this place recently. */
function recentGroupmates(lastCheckInDoc, others) {
  const groupedWith = lastCheckInDoc.exists ? lastCheckInDoc.get('groupedWith') ?? {} : {};
  return others.filter((other) => {
    const at = groupedWith[other]?.toMillis();
    return at && Date.now() - at < GROUP_REPEAT_DAYS * 24 * 3600 * 1000;
  });
}

/** Returns check-in eligible places near the given position. */
exports.nearbyPlaces = onCall(LOCATION_CALLABLE, async (request) => {
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

  // Businesses: partner or not, and what a check-in is worth this month.
  const db = getFirestore();
  const businesses = places.filter((p) => BUSINESS_CATEGORIES.includes(p.category));
  const businessDocs = businesses.length === 0 ? [] :
    await db.getAll(...businesses.map((p) => db.collection('businesses').doc(p.id)));
  const tiers = new Map(businesses.map((p, i) => [p.id, partnerTier(businessDocs[i])]));
  const partners = places.filter((p) => tiers.get(p.id));
  const budgetDocs = partners.length === 0 ? [] : await db.getAll(...partners.map((p) => budgetRef(db, p.id)));
  const budgets = new Map(partners.map((p, i) => [p.id, budgetDocs[i]]));

  for (const p of places) {
    const tier = tiers.get(p.id) ?? null;
    p.partner = tier !== null;
    p.tier = tier;
    p.requiresCode = p.partner;
    p.budgetUsedUp = p.partner && budgetUsedUp(tier, budgets.get(p.id));
    p.points = p.partner ? checkInPoints(tier, budgets.get(p.id)) : TOURISTIC_POINTS;
  }
  logger.info('nearbyPlaces', {
    uid: request.auth.uid, found: data.places?.length ?? 0, eligible: places.length, partners: partners.length,
    appCheck: appCheckStatus(request),
  });
  return { places };
});

// Group check-ins: at a partner business, the customer who uses the code
// can invite up to GROUP_MAX_SIZE - 1 friends. Each friend joins from their
// own phone (joinGroup) within GROUP_WINDOW_MINUTES, at the place. Everyone's
// base points are multiplied by GROUP_MULTIPLIERS for the group's size, and
// members are topped up as each friend joins.
const GROUP_MAX_SIZE = 6;
const GROUP_WINDOW_MINUTES = 10;
const GROUP_MULTIPLIERS = { 1: 1, 2: 1.5, 3: 2, 4: 3, 5: 3.5, 6: 5 };

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
 * The caller must be within CHECK_IN_RANGE_METERS of it, at most once every
 * CHECK_IN_COOLDOWN_HOURS and MAX_CHECK_INS_PER_PLACE_PER_WEEK times a week.
 * Businesses must be partners (see Partners): the caller gives the staff's
 * current code, which then can't be used again, and may invite friends
 * (friendUids) to join as a group.
 */
exports.performCheckIn = onCall(LOCATION_CALLABLE, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to check in.');
  }
  const db = getFirestore();
  const devTester = await throwUnlessFromApp(db, uid, request, 'performCheckIn');
  const placeId = readPlaceId(request.data?.placeId);
  const device = readDeviceFix(request.data);
  if (!devTester) throwIfUntrustedFix(device);

  const place = toPlace(await placesRequest(`places/${placeId}`, {
    fieldMask: PLACE_FIELDS.join(','),
  }));
  if (!isCheckInEligible(place.types)) {
    throw new HttpsError('failed-precondition', `${place.name} isn't a place you can check in at.`);
  }

  const distance = distanceMeters(device.lat, device.lng, place.latitude, place.longitude);
  logger.info('performCheckIn', {
    uid, placeId, place: place.name, distance: Math.round(distance), accuracy: Math.round(device.accuracy),
    isMocked: device.isMocked, devTester, appCheck: appCheckStatus(request),
  });
  if (distance > CHECK_IN_RANGE_METERS) {
    throw new HttpsError('failed-precondition',
      `Too far away - get within ${CHECK_IN_RANGE_METERS}m to check in (currently ${Math.round(distance)}m away).`);
  }

  const userRef = db.collection('users').doc(uid);
  const placeRef = db.collection('places').doc(placeId);
  const lastCheckInRef = db.collection('users').doc(uid).collection('placeCheckIns').doc(placeId);
  const checkInRef = db.collection('checkIns').doc();

  const isBusiness = BUSINESS_CATEGORIES.includes(place.category);
  const businessDoc = isBusiness ? await db.collection('businesses').doc(placeId).get() : null;
  const tier = partnerTier(businessDoc);
  if (isBusiness && !tier) {
    throw new HttpsError('failed-precondition', `${place.name} isn't a partner yet, so you can't check in there.`);
  }
  throwIfOwnPlace(businessDoc, uid, place);

  const friendUids = await readGroupFriends(db, uid, request.data?.friendUids);
  if (friendUids.length > 0 && !tier) {
    throw new HttpsError('failed-precondition', 'Group check-ins are only available at partner businesses.');
  }
  if (friendUids.includes(businessDoc?.get('ownerUid'))) {
    throw new HttpsError('failed-precondition', `You can't invite the manager of ${place.name}.`);
  }

  // Checked first so a code can't be used up, or count as a wrong guess,
  // when the check-in would be refused anyway. The transaction below checks
  // again.
  const lastBefore = await lastCheckInRef.get();
  throwIfCheckInLimitReached(lastBefore, place);
  throwIfRepeatGroup(lastBefore, friendUids, place);
  if (!devTester) throwIfImpossibleTravel(await userRef.get(), place);
  if (tier) {
    await useBusinessCode(db, uid, place, request.data?.code);
  }

  const groupRef = friendUids.length > 0 ? db.collection('groups').doc() : null;

  const result = await db.runTransaction(async (tx) => {
    const [userDoc, lastDoc, budgetDoc] = await Promise.all([
      tx.get(userRef), tx.get(lastCheckInRef), tier ? tx.get(budgetRef(db, placeId)) : null,
    ]);

    if (!userDoc.exists || userDoc.get('phoneVerified') !== true) {
      throw new HttpsError('failed-precondition', 'Verify your phone number before checking in.');
    }

    throwIfCheckInLimitReached(lastDoc, place);
    if (!devTester) throwIfImpossibleTravel(userDoc, place);

    const base = checkInPoints(tier, budgetDoc);
    const points = tier ? awardPartnerPoints(tx, userRef, userDoc, base) : base;
    if (!tier) tx.update(userRef, { points: FieldValue.increment(points) });
    if (tier) useBudget(tx, db, placeId);

    const now = FieldValue.serverTimestamp();
    tx.set(placeRef, {
      name: place.name,
      latitude: place.latitude,
      longitude: place.longitude,
      types: place.types,
      category: place.category,
      timesCheckedIn: FieldValue.increment(1),
    }, { merge: true });
    tx.set(lastCheckInRef, placeCheckInUpdate(lastDoc), { merge: true });
    tx.set(checkInRef, {
      uid, placeId, placeName: place.name, tier, basePoints: base, points, distanceMeters: Math.round(distance),
      createdAt: now, ...(groupRef ? { groupId: groupRef.id } : {}),
    });
    tx.update(userRef, { lastCheckIn: lastCheckInOf(place) });

    if (groupRef) {
      const expiresAt = Timestamp.fromMillis(Date.now() + GROUP_WINDOW_MINUTES * 60 * 1000);
      tx.set(groupRef, {
        placeId,
        placeName: place.name,
        latitude: place.latitude,
        longitude: place.longitude,
        tier,
        ownerUid: businessDoc.get('ownerUid'),
        primaryUid: uid,
        members: [uid],
        invited: friendUids,
        basePoints: { [uid]: base },
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
    return { pointsEarned: points, capped: points < base, budgetUsedUp: !!tier && budgetUsedUp(tier, budgetDoc) };
  });

  logger.info('Checked in', { uid, placeId, tier, ...result, groupId: groupRef?.id, invited: friendUids.length });
  return {
    ...result,
    placeName: place.name,
    groupId: groupRef?.id ?? null,
    invited: friendUids.length,
    groupWindowMinutes: GROUP_WINDOW_MINUTES,
    dailyPartnerPointsCap: DAILY_PARTNER_POINTS_CAP,
  };
});

function throwIfRepeatGroup(lastCheckInDoc, others, place) {
  if (recentGroupmates(lastCheckInDoc, others).length > 0) {
    throw new HttpsError('failed-precondition',
      `You can only check in at ${place.name} as a group with the same friend once every ` +
      `${GROUP_REPEAT_DAYS} days. Leave out friends you've been there with this week.`);
  }
}

/**
 * Joins a group check-in the caller was invited to. The caller must be at the
 * place, within its check-in limits, and not in a group there with any member
 * in the last GROUP_REPEAT_DAYS; joining counts as their check-in. Everyone in
 * the group, including the caller, is brought up to their base points times
 * the new size's multiplier, as far as each one's daily cap allows.
 */
exports.joinGroup = onCall(LOCATION_CALLABLE, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to join a group check-in.');
  }
  const db = getFirestore();
  const devTester = await throwUnlessFromApp(db, uid, request, 'joinGroup');
  const groupId = request.data?.groupId;
  if (typeof groupId !== 'string' || !/^[A-Za-z0-9]{1,64}$/.test(groupId)) {
    throw new HttpsError('invalid-argument', 'A valid group is required.');
  }
  const device = readDeviceFix(request.data);
  if (!devTester) throwIfUntrustedFix(device);
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
  logger.info('joinGroup', {
    uid, groupId, placeId: place.id, distance: Math.round(distance), accuracy: Math.round(device.accuracy),
    isMocked: device.isMocked, devTester, appCheck: appCheckStatus(request),
  });
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
    const tier = Object.hasOwn(TIERS, group.tier) ? group.tier : null;
    const memberRefs = members.map((m) => db.collection('users').doc(m));
    const [budgetDoc, ...memberDocs] = await Promise.all([
      tier ? tx.get(budgetRef(db, place.id)) : null,
      ...memberRefs.map((ref) => tx.get(ref)),
    ]);

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
    if (group.ownerUid === uid) {
      throw new HttpsError('permission-denied', `You can't check in at ${place.name}, since you manage it.`);
    }
    throwIfCheckInLimitReached(lastDoc, place);
    const repeats = recentGroupmates(lastDoc, members);
    if (repeats.length > 0) {
      throw new HttpsError('failed-precondition',
        `You've already been in a group at ${place.name} with someone in this one in the last ` +
        `${GROUP_REPEAT_DAYS} days. You can still check in there on your own.`);
    }
    if (!devTester) throwIfImpossibleTravel(userDoc, place);

    const newMembers = [...members, uid];
    const size = newMembers.length;
    const multiplier = GROUP_MULTIPLIERS[size];
    const myBase = checkInPoints(tier, budgetDoc);
    const base = { ...group.basePoints, [uid]: myBase };
    const awarded = { ...group.awarded };
    const refs = [...memberRefs, userRef];
    const docs = [...memberDocs, userDoc];
    let capped = false;
    newMembers.forEach((member, i) => {
      const wanted = Math.round(base[member] * multiplier) - (awarded[member] ?? 0);
      if (wanted <= 0) return;
      const given = awardPartnerPoints(tx, refs[i], docs[i], wanted);
      awarded[member] = (awarded[member] ?? 0) + given;
      if (member === uid) capped = given < wanted;
    });
    if (tier) useBudget(tx, db, place.id);

    const full = size >= GROUP_MAX_SIZE;
    tx.update(groupRef, { members: newMembers, basePoints: base, awarded, size, status: full ? 'full' : 'open' });

    const now = FieldValue.serverTimestamp();
    const nowTs = Timestamp.now();
    tx.set(lastCheckInRef, {
      ...placeCheckInUpdate(lastDoc),
      groupedWith: Object.fromEntries(members.map((m) => [m, nowTs])),
    }, { merge: true });
    for (const member of members) {
      tx.set(db.doc(`users/${member}/placeCheckIns/${place.id}`), { groupedWith: { [uid]: nowTs } }, { merge: true });
    }
    tx.update(userRef, { lastCheckIn: lastCheckInOf(place) });
    tx.set(checkInRef, {
      uid, placeId: place.id, placeName: place.name, tier, basePoints: myBase, points: awarded[uid] ?? 0, groupId,
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
    return { pointsEarned: awarded[uid] ?? 0, groupSize: size, multiplier, capped };
  });

  logger.info('Joined group', { uid, groupId, ...result });
  return { ...result, placeName: place.name, dailyPartnerPointsCap: DAILY_PARTNER_POINTS_CAP };
});

// ---------------------------------------------------------------------------
// Business codes
//
// A restaurant, café, hotel or shop can claim its place (requestBusinessClaim); the
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

/** Asks to manage a restaurant, café, hotel or shop. Approved by an admin. */
exports.requestBusinessClaim = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to register your business.');
  }
  const db = getFirestore();
  await throwUnlessFromApp(db, uid, request, 'requestBusinessClaim');
  const placeId = readPlaceId(request.data?.placeId);
  const place = toPlace(await placesRequest(`places/${placeId}`, { fieldMask: PLACE_FIELDS.join(',') }));
  if (!BUSINESS_CATEGORIES.includes(place.category)) {
    throw new HttpsError('failed-precondition', 'Only restaurants, cafés, hotels and shops can be registered.');
  }

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
  const db = getFirestore();
  await throwUnlessFromApp(db, uid, request, 'getBusinessCode');
  const placeId = readPlaceId(request.data?.placeId);
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
  const db = getFirestore();
  await throwUnlessFromApp(db, uid, request, 'newBusinessCode');
  const placeId = readPlaceId(request.data?.placeId);
  const businessDoc = await readOwnBusiness(db, uid, placeId);
  const { code, expiresAt, seq } = await currentBusinessCode(db, placeId, { retire: true });
  logger.info('newBusinessCode', { uid, placeId, seq });
  return { code, expiresAt, seq, placeName: businessDoc.get('placeName') };
});

/**
 * Check-in counts for a place the caller manages: since the start of the
 * owner's day (todayStart, sent by the app since it knows the time zone), the
 * last 7 days, and since approval, plus group check-ins, and its partner tier
 * and this month's budget use. Counts only - owners never see who checked in.
 */
exports.getBusinessStats = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Sign in to see your business stats.');
  }
  const db = getFirestore();
  await throwUnlessFromApp(db, uid, request, 'getBusinessStats');
  const placeId = readPlaceId(request.data?.placeId);
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
  const tier = partnerTier(businessDoc);
  const budgetDoc = tier ? await budgetRef(db, placeId).get() : null;
  return {
    tier,
    tierLabel: tier ? TIERS[tier].label : null,
    tierPoints: tier ? TIERS[tier].points : null,
    monthlyBudget: tier ? TIERS[tier].monthlyBudget : null,
    usedThisMonth: budgetDoc?.exists ? budgetDoc.get('used') ?? 0 : 0,
    today,
    week,
    sinceApproval,
    groupCheckIns: groupCount,
    averageGroupSize: groupCount ? Math.round((groupMembers / groupCount) * 10) / 10 : null,
  };
});

// ---------------------------------------------------------------------------
// Check-in spikes
//
// Every 15 minutes, flags places with an unusual number of check-ins in the
// last hour: at least SPIKE_MIN_CHECK_INS, and SPIKE_FACTOR times their
// hourly average over the last 7 days. Each flag is logged as
// 'Check-in spike' and stored in alerts/{placeId}_{hour}, once per place per
// hour (scripts/alerts.js lists them).
// ---------------------------------------------------------------------------

const SPIKE_MIN_CHECK_INS = 15;
const SPIKE_FACTOR = 5;

exports.checkInSpikes = onSchedule('every 15 minutes', async () => {
  const db = getFirestore();
  const now = Date.now();
  const lastHour = await db.collection('checkIns')
    .where('createdAt', '>=', Timestamp.fromMillis(now - 3600 * 1000))
    .select('placeId', 'placeName').get();

  const counts = new Map();
  for (const doc of lastHour.docs) {
    const entry = counts.get(doc.get('placeId')) ?? { placeName: doc.get('placeName'), count: 0 };
    entry.count += 1;
    counts.set(doc.get('placeId'), entry);
  }

  for (const [placeId, { placeName, count }] of counts) {
    if (count < SPIKE_MIN_CHECK_INS) continue;
    const week = (await db.collection('checkIns')
      .where('placeId', '==', placeId)
      .where('createdAt', '>=', Timestamp.fromMillis(now - WEEK_MS))
      .count().get()).data().count;
    const hourlyAverage = week / (7 * 24);
    if (count < SPIKE_FACTOR * hourlyAverage) continue;

    const alert = { placeId, placeName, lastHour: count, hourlyAverage: Math.round(hourlyAverage * 10) / 10 };
    try {
      await db.collection('alerts').doc(`${placeId}_${new Date(now).toISOString().slice(0, 13)}`).create({
        type: 'checkInSpike', ...alert, createdAt: FieldValue.serverTimestamp(),
      });
    } catch (err) {
      if (err.code === 6) continue; // ALREADY_EXISTS: flagged this hour already
      throw err;
    }
    logger.warn('Check-in spike', alert);
  }
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
