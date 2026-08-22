const List<String> allowedPlaceTypes = [
  'restaurant',
  'cafe',
  'museum',
  'shopping_mall',
  'tourist_attraction',
  'park',
  'natural_feature',
  'zoo',
  'art_gallery',
  'stadium',
  'amusement_park',
  'landmark',
  'place_of_worship',
  'library',
];

const List<String> blockedPlaceTypes = [
  'lodging',
  'premise',
  'subpremise',
  'residential',
  'street_address',
];

class PlaceInfo {
  final String name;
  final List<String> types;

  PlaceInfo({required this.name, required this.types});
}

bool isCheckInEligible(PlaceInfo place) {
  for (String type in place.types) {
    if (blockedPlaceTypes.contains(type)) {
      return false;
    }
  }

  for (String type in place.types) {
    if (allowedPlaceTypes.contains(type)) {
      return true;
    }
  }

  return false;
}