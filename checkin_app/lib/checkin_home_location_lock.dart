class User {
  final String name;
  double homeLatitude;
  double homeLongitude;
  DateTime homeLastChanged;

  User({
    required this.name,
    required this.homeLatitude,
    required this.homeLongitude,
    required this.homeLastChanged,
  });
}

const int homeChangeCooldownDays = 365;

bool canChangeHomeLocation(User user, DateTime now) {
  int daysSinceChange = now.difference(user.homeLastChanged).inDays;
  return daysSinceChange >= homeChangeCooldownDays;
}

bool updateHomeLocation(User user, double newLat, double newLng, DateTime now) {
  if (!canChangeHomeLocation(user, now)) {
    int daysLeft = homeChangeCooldownDays - now.difference(user.homeLastChanged).inDays;
    print('${user.name} cannot change home city yet. $daysLeft days remaining.');
    return false;
  }

  user.homeLatitude = newLat;
  user.homeLongitude = newLng;
  user.homeLastChanged = now;
  print('${user.name}\'s home city updated successfully.');
  return true;
}