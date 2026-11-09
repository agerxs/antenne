import 'package:antenne/core/models.dart';
import 'package:antenne/ui/channel_groups.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const a = Channel(name: 'A', url: 'http://x/a', group: 'France');
  const b = Channel(name: 'B', url: 'http://x/b', group: 'Sport');
  const c = Channel(name: 'C', url: 'http://x/c', group: 'France');

  test('une liste à plusieurs groupes : toute la liste en tête, puis chaque groupe', () async {
    final groups = ChannelGroups.fromList([a, b, c]);
    expect(groups.names, ['Toutes les chaînes', 'France', 'Sport']);
    expect(await groups.channels(0), [a, b, c]);
    expect(await groups.channels(1), [a, c]);
    expect(await groups.channels(2), [b]);
  });

  test('une liste sans groupes porte le nom donné', () async {
    final groups = ChannelGroups.fromList([const Channel(name: 'D', url: 'http://x/d')], title: 'Favoris');
    expect(groups.names, ['Favoris']);
    expect((await groups.channels(0)).single.name, 'D');
  });

  test('un chargement réussi est gardé, un échec est retenté', () async {
    var calls = 0;
    final groups = ChannelGroups(
      names: ['Direct'],
      load: (_) async {
        calls++;
        if (calls == 1) throw Exception('réseau');
        return [a];
      },
    );
    await expectLater(groups.channels(0), throwsException);
    expect(await groups.channels(0), [a]);
    expect(await groups.channels(0), [a]);
    expect(calls, 2);
  });
}
