import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// DEV_TOOLS Android builds only: shows this install's App Check debug code,
/// to add in the Firebase console (App Check > Chekkin Android > Manage debug
/// tokens). Until it's added, App Check fails and only dev testers can check
/// in.
class DevAppCheckScreen extends StatefulWidget {
  const DevAppCheckScreen({super.key});

  @override
  State<DevAppCheckScreen> createState() => _DevAppCheckScreenState();
}

class _DevAppCheckScreenState extends State<DevAppCheckScreen> {
  static const _channel = MethodChannel('chekkin/dev');

  String? secret;
  bool loading = true;
  // Whether App Check currently gives this install a token.
  bool? verified;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    // Asking for a token makes the debug provider create its code if it
    // hasn't yet, and tells us whether the code has been added.
    bool ok;
    try {
      ok = await FirebaseAppCheck.instance.getToken(true) != null;
    } catch (e) {
      debugPrint('App Check token failed: $e');
      ok = false;
    }
    String? found;
    try {
      found = await _channel.invokeMethod<String>('appCheckDebugSecret');
    } catch (e) {
      debugPrint('Reading the App Check debug code failed: $e');
    }
    if (!mounted) return;
    setState(() {
      secret = found;
      verified = ok;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DEV: App Check')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Add this code in the Firebase console: App Check > Apps > Chekkin Android > ⋮ > Manage debug '
            'tokens. Then close and reopen the app. Keep the code private: anyone with it passes App Check.',
          ),
          const SizedBox(height: 16),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else if (secret == null)
            const Text('No code yet. Go back to the map, then open this screen again.')
          else ...[
            SelectableText(secret!, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: secret!));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                }
              },
            ),
          ],
          if (!loading) ...[
            const SizedBox(height: 24),
            Text(
              verified == true
                  ? 'App Check: verified. This install can check in.'
                  : 'App Check: not verified yet. Add the code, then tap Refresh.',
              style: TextStyle(color: verified == true ? Colors.green[800] : Colors.red[800]),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(icon: const Icon(Icons.refresh), label: const Text('Refresh'), onPressed: _load),
          ],
        ],
      ),
    );
  }
}
