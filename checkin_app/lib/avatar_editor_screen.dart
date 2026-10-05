import 'package:avatar_maker/avatar_maker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'user_avatar.dart';

/// Build a cartoon avatar: face, hair, clothes and so on, with a live preview.
class AvatarEditorScreen extends StatefulWidget {
  /// The user's current avatar as stored in Firestore, if they have one.
  final Map? currentAvatar;

  const AvatarEditorScreen({super.key, this.currentAvatar});

  @override
  State<AvatarEditorScreen> createState() => _AvatarEditorScreenState();
}

class _AvatarEditorScreenState extends State<AvatarEditorScreen> {
  late final NonPersistentAvatarMakerController controller = newAvatarController(stored: widget.currentAvatar);
  bool isSaving = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => isSaving = true);
    try {
      String uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'avatar': encodeAvatar(controller.selectedOptions),
        'profileImage': 'avatar',
      });
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      debugPrint('Saving avatar failed: $e');
      if (!mounted) return;
      setState(() => isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t save your avatar. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    double width = MediaQuery.of(context).size.width;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Avatar'),
        actions: [
          TextButton(
            onPressed: isSaving ? null : _save,
            child: isSaving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 16),
            AvatarMakerAvatar(
              controller: controller,
              radius: 80,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            TextButton.icon(
              icon: const Icon(Icons.shuffle),
              label: const Text('Shuffle'),
              onPressed: controller.randomizedSelectedOptions,
            ),
            AvatarMakerCustomizer(
              controller: controller,
              scaffoldWidth: width > 600 ? 600 : width,
              scaffoldHeight: 380,
            ),
          ],
        ),
      ),
    );
  }
}
