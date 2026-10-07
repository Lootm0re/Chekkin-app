import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return android;
    }
    throw UnsupportedError(
      'DefaultFirebaseOptions are not supported for this platform.',
    );
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCgs0Srui62pfBYED8zQbQQuWMd4MystwA',
    authDomain: 'chekkin-c6653.firebaseapp.com',
    projectId: 'chekkin-c6653',
    storageBucket: 'chekkin-c6653.firebasestorage.app',
    messagingSenderId: '929780239850',
    appId: '1:929780239850:web:3d9a294c8ace320d45f693',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAqfD75MZlC0gsECStoaWf1NAi25Mtn6rk',
    appId: '1:929780239850:android:528c6d1770ddd6cd45f693',
    messagingSenderId: '929780239850',
    projectId: 'chekkin-c6653',
    storageBucket: 'chekkin-c6653.firebasestorage.app',
  );
}
