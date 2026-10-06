import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ProfilePictureUploader {
  final ImagePicker picker = ImagePicker();

  /// Uploads the photo and shows it instead of the avatar. Its URL appears in
  /// users/{uid}.profilePictureUrl a few seconds later, set by the
  /// publishProfilePicture function.
  Future<void> pickAndUploadPhoto() async {
    XFile? picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      imageQuality: 80,
    );

    if (picked == null) return;

    String uid = FirebaseAuth.instance.currentUser!.uid;
    Reference storageRef = FirebaseStorage.instance.ref().child('profile_pictures/$uid.jpg');

    // putData rather than putFile, which needs dart:io and fails on web.
    await storageRef.putData(
      await picked.readAsBytes(),
      SettableMetadata(contentType: picked.mimeType ?? 'image/jpeg'),
    );

    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'profileImage': 'photo',
    });
  }
}
