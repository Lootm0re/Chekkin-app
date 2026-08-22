import 'dart:math';

class Location {
  final String name;
  final double latitude;
  final double longitude;
  int timesCheckedIn;

  Location({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.timesCheckedIn = 0,
  });
}

class User {
  final String name;
  final double homeLatitude;
  final double homeLongitude;

  User({
    required this.name,
    required this.homeLatitude,
    required this.homeLongitude,
  });
}

double distanceInKm(double lat1, double lon1, double lat2, double lon2) {
  const double earthRadiusKm = 6371;
  double dLat = _degToRad(lat2 - lat1);
  double dLon = _degToRad(lon2 - lon1);

  double a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_degToRad(lat1)) * cos(_degToRad(lat2)) *
      sin(dLon / 2) * sin(dLon / 2);
  double c = 2 * atan2(sqrt(a), sqrt(1 - a));

  return earthRadiusKm * c;
}

double _degToRad(double degrees) => degrees * pi / 180;

int rarityPoints(Location place) {
  const int basePoints = 10;

  if (place.timesCheckedIn == 0) {
    return basePoints * 100;
  } else if (place.timesCheckedIn < 10) {
    return basePoints * 20;
  } else if (place.timesCheckedIn < 100) {
    return basePoints * 5;
  } else {
    return basePoints;
  }
}

double distanceMultiplier(double distanceKm) {
  double multiplier = 1.0 + (distanceKm / 500) * 0.10;
  return min(multiplier, 3.0);
}

int calculateTotalPoints(Location place, User user) {
  int rarity = rarityPoints(place);

  double distance = distanceInKm(
    user.homeLatitude,
    user.homeLongitude,
    place.latitude,
    place.longitude,
  );

  double multiplier = distanceMultiplier(distance);

  int total = (rarity * multiplier).round();

  return total;
}