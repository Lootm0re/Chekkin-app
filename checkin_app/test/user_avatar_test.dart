import 'package:avatar_maker/avatar_maker.dart';
import 'package:checkin_app/avatar_editor_screen.dart';
import 'package:checkin_app/user_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an avatar survives saving and loading', () {
    var controller = newAvatarController();
    controller.randomizedSelectedOptions();
    Map<String, String> stored = encodeAvatar(controller.selectedOptions);

    expect(stored['HairStyle'], isNotNull);
    expect(encodeAvatar(decodeAvatar(stored)), stored);
  });

  test('unknown or missing parts fall back to the defaults', () {
    var defaults = encodeAvatar(decodeAvatar(null));
    var decoded = encodeAvatar(decodeAvatar({'HairStyle': 'NoSuchHair', 'Bogus': 'x'}));

    expect(decoded, defaults);
    expect(decoded.keys, containsAll(['SkinColor', 'HairStyle', 'OutfitType']));
  });

  test('a stored part is used', () {
    var defaults = decodeAvatar(null);
    String otherSkin = SkinColors.values.firstWhere((c) => c != defaults[PropertyCategoryIds.SkinColor]).id;

    expect(encodeAvatar(decodeAvatar({'SkinColor': otherSkin}))['SkinColor'], otherSkin);
  });

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));
  final avatar = {'HairStyle': 'HairStyles/Long', 'SkinColor': 'SkinColor/Brown'};

  testWidgets('no photo or avatar (or hidden): the default icon', (tester) async {
    await tester.pumpWidget(wrap(const UserAvatar(data: {'name': 'A'})));
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.byType(AvatarMakerAvatar), findsNothing);
  });

  testWidgets('an avatar is drawn', (tester) async {
    await tester.pumpWidget(wrap(UserAvatar(data: {'avatar': avatar})));
    await tester.pump();
    expect(find.byType(AvatarMakerAvatar), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing);
  });

  testWidgets('photo and avatar: the avatar when chosen', (tester) async {
    await tester.pumpWidget(wrap(UserAvatar(data: {
      'avatar': avatar,
      'profilePictureUrl': 'https://example.com/p.jpg',
      'profileImage': 'avatar',
    })));
    await tester.pump();
    expect(find.byType(AvatarMakerAvatar), findsOneWidget);
  });

  testWidgets('the editor starts from the saved avatar and shuffles', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(home: AvatarEditorScreen(currentAvatar: avatar)));
    await tester.pumpAndSettle();

    var editor = tester.state(find.byType(AvatarEditorScreen)) as dynamic;
    Map<String, String> before = encodeAvatar(editor.controller.selectedOptions);
    expect(before['HairStyle'], 'HairStyles/Long');
    expect(before['SkinColor'], 'SkinColor/Brown');

    // Random, so allow a few tries for it to differ.
    for (var i = 0; i < 5 && encodeAvatar(editor.controller.selectedOptions).toString() == before.toString(); i++) {
      await tester.tap(find.text('Shuffle'));
      await tester.pumpAndSettle();
    }
    expect(encodeAvatar(editor.controller.selectedOptions), isNot(before));
  });
}
