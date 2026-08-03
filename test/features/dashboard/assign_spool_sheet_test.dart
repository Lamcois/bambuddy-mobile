import 'dart:async';

import 'package:bambuddy_mobile/core/api/api_exceptions.dart';
import 'package:bambuddy_mobile/core/models/printer.dart';
import 'package:bambuddy_mobile/core/models/printer_status.dart';
import 'package:bambuddy_mobile/core/settings/server_profile.dart';
import 'package:bambuddy_mobile/data/printers_repository.dart';
import 'package:bambuddy_mobile/features/dashboard/smart_plugs_providers.dart';
import 'package:bambuddy_mobile/features/dashboard/widgets/printer_card.dart';
import 'package:bambuddy_mobile/features/inventory/inventory_providers.dart';
import 'package:bambuddy_mobile/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

class _FakeProfileNotifier extends ServerProfileNotifier {
  @override
  ServerProfile? build() => const ServerProfile(
        baseUrl: 'http://s.local:8000',
        authMode: AuthMode.none,
      );
}

class _InertSmartPlugsNotifier extends SmartPlugsNotifier {
  @override
  SmartPlugsState build() => const SmartPlugsState();
}

/// Magazyn w zadanym stanie, bez sieci. [refreshes] liczy ponowne próby, bo
/// „da się jeszcze raz spytać" jest tu istotą naprawy.
class _FakeInventoryNotifier extends InventoryNotifier {
  _FakeInventoryNotifier(this._state);

  final Future<InventoryState> Function() _state;
  int refreshes = 0;

  @override
  Future<InventoryState> build() => _state();

  @override
  Future<void> refresh() async => refreshes++;
}

/// Drukarka z realnym AMS-em (ta sama ramka co w testach karty) — sloty AMS są
/// tu wierszami, które otwierają arkusz przypisania.
PrinterWithStatus _item() {
  final frame = readFixture('ws_printer_status.json') as Map<String, dynamic>;
  final data = Map<String, dynamic>.from(frame['data'] as Map);
  data['id'] = frame['printer_id'];
  // Miniatura okładki wisiałaby na żądaniu HTTP w teście.
  data.remove('cover_url');
  return PrinterWithStatus(
    printer: const Printer(id: 1, name: 'X2D-3DP'),
    status: PrinterStatus.fromJson(data),
  );
}

Widget _card(_FakeInventoryNotifier inventory) => ProviderScope(
      overrides: [
        serverProfileProvider.overrideWith(_FakeProfileNotifier.new),
        cameraTokenProvider.overrideWith((ref) async => 'tok'),
        inertFirmwareOverride,
        inertTotalPrintHoursOverride,
        smartPlugsProvider.overrideWith(_InertSmartPlugsNotifier.new),
        inventoryProvider.overrideWith(() => inventory),
      ],
      child: plApp(
        Scaffold(body: SingleChildScrollView(child: PrinterCard(item: _item()))),
      ),
    );

/// Rozwija szczegóły karty i otwiera arkusz przypisania z pierwszego wiersza
/// AMS. Bez `pumpAndSettle` — drukarka drukuje, więc pasek postępu animuje się
/// bez końca (jak w [printer_card_test]).
Future<void> _openAssignSheet(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Szczegóły'));
  await tester.tap(find.text('Szczegóły'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));

  final slot = find.text('PLA Basic').first;
  await tester.ensureVisible(slot);
  await tester.pump();
  await tester.tap(slot);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('trwające ładowanie magazynu pokazuje spinner, nie „brak szpul"',
      (tester) async {
    // Nigdy nie kończy się — arkusz otwarty w trakcie pierwszego pobrania.
    final pending = Completer<InventoryState>();
    final inventory = _FakeInventoryNotifier(() => pending.future);

    await tester.pumpWidget(_card(inventory));
    await _openAssignSheet(tester);

    expect(find.text('Przypisz szpulę'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Brak szpul w magazynie'), findsNothing);
  });

  testWidgets('nieudane pobranie magazynu pokazuje błąd i pozwala powtórzyć',
      (tester) async {
    final inventory = _FakeInventoryNotifier(
      () => Future<InventoryState>.error(
        const NetworkException(AppErrorCode.connectionError),
        StackTrace.current,
      ),
    );

    await tester.pumpWidget(_card(inventory));
    await _openAssignSheet(tester);

    expect(find.text('Błąd połączenia'), findsOneWidget);

    await tester.tap(find.text('Spróbuj ponownie'));
    await tester.pump();
    expect(inventory.refreshes, 1);
  });

  testWidgets('pusty magazyn daje przycisk ponowienia, nie sam napis',
      (tester) async {
    final inventory = _FakeInventoryNotifier(
      () async => const InventoryState(),
    );

    await tester.pumpWidget(_card(inventory));
    await _openAssignSheet(tester);

    expect(find.text('Brak szpul w magazynie'), findsOneWidget);

    await tester.tap(find.text('Spróbuj ponownie'));
    await tester.pump();
    expect(inventory.refreshes, 1);
  });
}
