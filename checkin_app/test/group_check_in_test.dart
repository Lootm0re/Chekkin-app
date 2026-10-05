import 'dart:io';

import 'package:checkin_app/group_check_in.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multipliers are formatted without needless decimals', () {
    expect(formatMultiplier(1.5), '×1.5');
    expect(formatMultiplier(2), '×2');
    expect(formatMultiplier(5.0), '×5');
  });

  test('group rules match the server (functions/index.js)', () {
    String server = File('../functions/index.js').readAsStringSync();

    String multipliers = RegExp(r'const GROUP_MULTIPLIERS = \{([^}]*)\}').firstMatch(server)!.group(1)!;
    Map<int, double> serverMultipliers = {
      for (var m in RegExp(r'(\d+): ([\d.]+)').allMatches(multipliers)) int.parse(m[1]!): double.parse(m[2]!),
    };
    expect(groupMultipliers, serverMultipliers);

    int serverMax = int.parse(RegExp(r'const GROUP_MAX_SIZE = (\d+);').firstMatch(server)![1]!);
    expect(groupMaxSize, serverMax);
  });
}
