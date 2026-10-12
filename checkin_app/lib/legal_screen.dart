import 'package:flutter/material.dart';

import 'theme.dart';

enum LegalPage {
  terms('Terms of service', Icons.description_rounded),
  privacy('Privacy policy', Icons.privacy_tip_rounded);

  final String title;
  final IconData icon;

  const LegalPage(this.title, this.icon);
}

/// Placeholder until the real terms and privacy policy are written.
class LegalScreen extends StatelessWidget {
  final LegalPage page;

  const LegalScreen({super.key, required this.page});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(page.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconSquare(color: AppColors.sky, icon: page.icon),
                  const SizedBox(height: 14),
                  Text('Coming soon', style: AppText.heading(size: 22)),
                  const SizedBox(height: 6),
                  Text(
                    'The full ${page.title.toLowerCase()} will be here before Chekkin launches.',
                    style: AppText.body(color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
