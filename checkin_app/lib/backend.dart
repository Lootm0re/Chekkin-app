import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// The Firestore and Auth instances the screens use. In the app these are
/// the normal instances; widget tests swap in fakes (test/fakes.dart).
FirebaseFirestore get firestore => firestoreOverride ?? FirebaseFirestore.instance;
FirebaseAuth get firebaseAuth => authOverride ?? FirebaseAuth.instance;

@visibleForTesting
FirebaseFirestore? firestoreOverride;
@visibleForTesting
FirebaseAuth? authOverride;

/// Replaces cloudFunctions (emulators.dart) in widget tests. Not marked
/// @visibleForTesting because emulators.dart reads it.
FirebaseFunctions? functionsOverride;
