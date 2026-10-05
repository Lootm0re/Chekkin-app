import 'dart:convert';

import 'package:avatar_maker/avatar_maker.dart';
import 'package:flutter/material.dart';

/// Avatar parts left out of the editor: cosmetic backgrounds and effects,
/// which have no items unless an app adds its own. The package rejects a
/// category whose default isn't in its item list, so each lists its "none".
final List<CustomizedPropertyCategory> avatarCategories = [
  CustomizedPropertyCategory(
    id: PropertyCategoryIds.AvatarBackground,
    toDisplay: false,
    properties: [NoBackgroundItem()],
  ),
  CustomizedPropertyCategory(id: PropertyCategoryIds.AvatarEffect, toDisplay: false, properties: [NoEffectItem()]),
  CustomizedPropertyCategory(
    id: PropertyCategoryIds.AvatarEffectColor,
    toDisplay: false,
    properties: [NoEffectColorItem()],
  ),
];

/// An avatar as stored in Firestore: part name to item id, e.g.
/// {'HairStyle': 'HairStyles/Long', 'SkinColor': 'SkinColor/Brown'}.
Map<String, String> encodeAvatar(Map<PropertyCategoryIds, PropertyItem> options) {
  return {for (var entry in options.entries) entry.key.name: entry.value.id};
}

// Only used for its part lists and defaults, to decode stored avatars.
final NonPersistentAvatarMakerController _template =
    NonPersistentAvatarMakerController(customizedPropertyCategories: avatarCategories);

/// Turns a stored avatar back into editor options. Unknown or missing parts
/// (e.g. from a newer package version) fall back to the defaults.
Map<PropertyCategoryIds, PropertyItem> decodeAvatar(Map? stored) {
  Map<PropertyCategoryIds, PropertyItem> options = Map.of(_template.defaultSelectedOptions);
  if (stored == null) return options;
  for (var category in _template.propertyCategories) {
    Object? itemId = stored[category.id.name];
    PropertyItem? item = category.properties?.where((p) => p.id == itemId).firstOrNull;
    if (item != null) options[category.id] = item;
  }
  return options;
}

// The options go in through the constructor: the controller sets itself up
// asynchronously and would replace options assigned afterwards with defaults.
NonPersistentAvatarMakerController newAvatarController({Map? stored}) {
  return NonPersistentAvatarMakerController(
    customizedPropertyCategories: avatarCategories,
    selectedOptions: decodeAvatar(stored),
  );
}

// One controller per distinct avatar, so the leaderboard doesn't rebuild an
// avatar on every scroll.
final Map<String, NonPersistentAvatarMakerController> _controllerCache = {};

NonPersistentAvatarMakerController _cachedController(Map stored) {
  String key = jsonEncode(Map.fromEntries(stored.entries.toList()..sort((a, b) => '${a.key}'.compareTo('${b.key}'))));
  if (_controllerCache.length > 200) _controllerCache.clear();
  return _controllerCache.putIfAbsent(key, () => newAvatarController(stored: stored));
}

/// A user's picture: their uploaded photo or avatar, whichever they chose,
/// or a default icon if they have neither.
///
/// [data] is a users/{uid} or publicProfiles/{uid} document. Hiding is done
/// on the server: a hidden user's public profile has no photo or avatar.
class UserAvatar extends StatelessWidget {
  final Map<String, dynamic>? data;
  final double radius;

  const UserAvatar({super.key, required this.data, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    String? photoUrl = data?['profilePictureUrl'];
    Map? avatar = data?['avatar'] is Map ? data!['avatar'] : null;
    bool hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
    bool showPhoto = hasPhoto && (avatar == null || data?['profileImage'] != 'avatar');

    if (showPhoto) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(photoUrl));
    }
    if (avatar != null) {
      return AvatarMakerAvatar(
        controller: _cachedController(avatar),
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        usePreview: false,
      );
    }
    return CircleAvatar(radius: radius, child: Icon(Icons.person, size: radius));
  }
}
