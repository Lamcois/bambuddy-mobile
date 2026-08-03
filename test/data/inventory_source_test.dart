import 'package:bambuddy_mobile/core/models/inventory.dart';
import 'package:bambuddy_mobile/data/inventory_source.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

void main() {
  late Dio dio;
  late DioAdapter adapter;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://s.local:8000'));
    adapter = DioAdapter(dio: dio);
  });

  group('probeInventoryBackend', () {
    test('integracja włączona z adresem → spoolman', () async {
      adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.reply(200, {
          'enabled': true,
          'connected': true,
          'url': 'http://spoolman.local:7912',
        }),
      );
      expect(await probeInventoryBackend(dio), InventoryBackend.spoolman);
    });

    test('włączona, ale nieosiągalna → i tak spoolman (błąd ma wyjść z danych)',
        () async {
      adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.reply(200, {
          'enabled': true,
          'connected': false,
          'url': 'http://spoolman.local:7912',
        }),
      );
      expect(await probeInventoryBackend(dio), InventoryBackend.spoolman);
    });

    test('wyłączona → native', () async {
      adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.reply(200, {'enabled': false, 'connected': false, 'url': null}),
      );
      expect(await probeInventoryBackend(dio), InventoryBackend.native);
    });

    test('włączona bez adresu → native', () async {
      adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.reply(200, {'enabled': true, 'url': '   '}),
      );
      expect(await probeInventoryBackend(dio), InventoryBackend.native);
    });

    test('starszy serwer bez trasy (404) → native', () async {
      adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.reply(404, {'detail': 'Not Found'}),
      );
      expect(await probeInventoryBackend(dio), InventoryBackend.native);
    });

    test('klucz bez uprawnienia (403) → native', () async {
      adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.reply(403, {'detail': 'Forbidden'}),
      );
      expect(await probeInventoryBackend(dio), InventoryBackend.native);
    });

    test('odpowiedź listą (backend demo) → native', () async {
      adapter.onGet('/api/v1/spoolman/status', (s) => s.reply(200, const []));
      expect(await probeInventoryBackend(dio), InventoryBackend.native);
    });

    test('brak połączenia → native', () async {
      adapter.onGet(
        '/api/v1/spoolman/status',
        (s) => s.throws(
          0,
          DioException.connectionError(
            requestOptions: RequestOptions(path: '/api/v1/spoolman/status'),
            reason: 'nic nie nasłuchuje',
          ),
        ),
      );
      expect(await probeInventoryBackend(dio), InventoryBackend.native);
    });
  });

  group('SpoolmanInventorySource — przypisanie do slotu', () {
    late SpoolmanInventorySource source;
    late List<RequestOptions> sentRequests;

    setUp(() {
      source = SpoolmanInventorySource(dio);
      sentRequests = [];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            sentRequests.add(options);
            handler.next(options);
          },
        ),
      );
    });

    // Every request the source made, as `METHOD /path` — what the assertions
    // below are actually about, since a call to the wrong route is the bug
    // class here.
    List<String> calls() =>
        [for (final r in sentRequests) '${r.method} ${r.path}'];

    test('assignSpool wysyła spoolman_spool_id, nie spool_id', () async {
      adapter.onPost(
        '/api/v1/spoolman/inventory/slot-assignments',
        (s) => s.reply(200, const {'id': 12}),
        data: Matchers.any,
      );

      await source.assignSpool(
        const SpoolAssignmentDraft(
          spoolId: 12,
          printerId: 1,
          amsId: 0,
          trayId: 2,
        ),
      );

      expect(sentRequests.single.data, {
        'spoolman_spool_id': 12,
        'printer_id': 1,
        'ams_id': 0,
        'tray_id': 2,
      });
    });

    test('unassignSpool kasuje po id szpuli znalezionej w tym slocie', () async {
      adapter
        ..onGet(
          '/api/v1/spoolman/inventory/slot-assignments/all',
          (s) => s.reply(200, [
            {
              'spoolman_spool_id': 5,
              'printer_id': 1,
              'ams_id': 0,
              'tray_id': 1,
            },
            {
              'spoolman_spool_id': 9,
              'printer_id': 1,
              'ams_id': 0,
              'tray_id': 2,
            },
          ]),
        )
        ..onDelete(
          '/api/v1/spoolman/inventory/slot-assignments/9',
          (s) => s.reply(200, const {'status': 'ok'}),
        );

      await source.unassignSpool(1, 0, 2);

      expect(calls(), [
        'GET /api/v1/spoolman/inventory/slot-assignments/all',
        'DELETE /api/v1/spoolman/inventory/slot-assignments/9',
      ]);
    });

    test('unassignSpool obsługuje szpulę zewnętrzną (ams_id 255)', () async {
      adapter
        ..onGet(
          '/api/v1/spoolman/inventory/slot-assignments/all',
          (s) => s.reply(200, [
            {
              'spoolman_spool_id': 44,
              'printer_id': 2,
              'ams_id': 255,
              'tray_id': 0,
            },
          ]),
        )
        ..onDelete(
          '/api/v1/spoolman/inventory/slot-assignments/44',
          (s) => s.reply(200, const {'status': 'ok'}),
        );

      await source.unassignSpool(2, 255, 0);

      expect(
        calls().last,
        'DELETE /api/v1/spoolman/inventory/slot-assignments/44',
      );
    });

    test('unassignSpool na pustym slocie nic nie kasuje', () async {
      adapter.onGet(
        '/api/v1/spoolman/inventory/slot-assignments/all',
        (s) => s.reply(200, const []),
      );

      await source.unassignSpool(1, 0, 3);

      expect(calls(), ['GET /api/v1/spoolman/inventory/slot-assignments/all']);
    });

    test('resetUsage idzie na reset-consumed-counter (nie na reset-usage)',
        () async {
      adapter.onPost(
        '/api/v1/spoolman/inventory/spools/7/reset-consumed-counter',
        (s) => s.reply(200, const {'id': 7}),
      );

      await source.resetUsage(7);

      expect(
        calls().single,
        'POST /api/v1/spoolman/inventory/spools/7/reset-consumed-counter',
      );
    });
  });
}
