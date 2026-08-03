import 'package:bambuddy_mobile/core/api/api_client.dart';
import 'package:bambuddy_mobile/core/settings/server_profile.dart';
import 'package:bambuddy_mobile/data/inventory_source.dart';
import 'package:bambuddy_mobile/features/inventory/inventory_providers.dart';
import 'package:bambuddy_mobile/providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers.dart';

/// Wybór backendu magazynu: serwer decyduje, ustawienie tylko nadpisuje.
/// Serwer w trybie Spoolmana trzyma własną tabelę `/inventory/spools` pustą, więc
/// pomyłka nie kończy się błędem, tylko pustym magazynem (issue #5).
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    dio = Dio();
    adapter = DioAdapter(dio: dio);
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(
          ApiClient(
            profile: const ServerProfile(
              baseUrl: 'http://s.local:8000',
              authMode: AuthMode.none,
            ),
            credentials: InMemoryCredentialsStore(),
            dio: dio,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void mockSpoolmanStatus({required bool enabled}) => adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.reply(200, {
          'enabled': enabled,
          'connected': enabled,
          'url': enabled ? 'http://spoolman.local:7912' : null,
        }),
      );

  test('serwer w trybie Spoolmana → źródłem jest Spoolman', () async {
    mockSpoolmanStatus(enabled: true);
    final container = buildContainer();

    await container.read(inventoryBackendProbeProvider.future);

    expect(container.read(inventoryBackendProvider), InventoryBackend.spoolman);
    expect(container.read(inventorySourceProvider),
        isA<SpoolmanInventorySource>());
  });

  test('serwer bez Spoolmana → źródłem jest backend natywny', () async {
    mockSpoolmanStatus(enabled: false);
    final container = buildContainer();

    await container.read(inventoryBackendProbeProvider.future);

    expect(container.read(inventoryBackendProvider), InventoryBackend.native);
    expect(
        container.read(inventorySourceProvider), isA<NativeInventorySource>());
  });

  test('ustawienie użytkownika wygrywa z odpowiedzią serwera', () async {
    SharedPreferences.setMockInitialValues({'inventory_backend': 'native'});
    prefs = await SharedPreferences.getInstance();
    mockSpoolmanStatus(enabled: true);
    final container = buildContainer();

    await container.read(inventoryBackendProbeProvider.future);

    expect(container.read(inventoryBackendProvider), InventoryBackend.native);
  });

  test('pierwsze pobranie czeka na wykrycie i idzie od razu do Spoolmana',
      () async {
    mockSpoolmanStatus(enabled: true);
    final sent = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          sent.add(options.path);
          handler.next(options);
        },
      ),
    );
    adapter
      ..onGet(
        '/api/v1/spoolman/inventory/spools',
        (s) => s.reply(200, const []),
        queryParameters: {'include_archived': true},
      )
      ..onGet(
        '/api/v1/spoolman/inventory/slot-assignments/all',
        (s) => s.reply(200, const []),
      );

    final container = buildContainer();
    await container.read(inventoryProvider.future);

    // Ani jednego strzału w tabelę natywną — to ona odpowiada pustą listą na
    // serwerze pod Spoolmanem, a wynik zdążyłby trafić na ekran.
    expect(sent, isNot(contains('/api/v1/inventory/spools')));
    expect(sent, contains('/api/v1/spoolman/inventory/spools'));
  });
}
