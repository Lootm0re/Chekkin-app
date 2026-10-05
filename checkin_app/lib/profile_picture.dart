import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ProfilePictureUploader {
  final ImagePicker picker = ImagePicker();

  Future<String?> pickAndUploadPhoto() async {
    XFile? picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      imageQuality: 80,
    );

    if (picked == null) return null;

    String uid = FirebaseAuth.instance.currentUser!.uid;
    Reference storageRef = FirebaseStorage.instance.ref().child('profile_pictures/$uid.jpg');

    // putData rather than putFile, which needs dart:io and fails on web.
    await storageRef.putData(
      await picked.readAsBytes(),
      SettableMetadata(contentType: picked.mimeType ?? 'image/jpeg'),
    );
    String downloadUrl = await storageRef.getDownloadURL();

    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'profilePictureUrl': downloadUrl,
      'profileImage': 'photo',
    });

    return downloadUrl;
  }
}
