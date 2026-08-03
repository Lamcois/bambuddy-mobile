import 'package:bambuddy_mobile/core/models/inventory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Spool.fromNative', () {
    test('parsuje pola i ignoruje nieznane klucze', () {
      final spool = Spool.fromNative({
        'id': 7,
        'material': 'PETG',
        'subtype': 'HF',
        'color_name': 'White',
        'rgba': 'FFFFFFFF',
        'brand': 'Professional Lab',
        'label_weight': 1000,
        'weight_used': 935,
        'cost_per_kg': 29.99,
        'storage_location': 'Szafa',
        'low_stock_threshold_pct': 10,
        'nieznane_pole': 'ignoruj',
      });

      expect(spool.id, 7);
      expect(spool.material, 'PETG');
      expect(spool.displayName, 'Professional Lab PETG HF');
      expect(spool.costPerKg, 29.99);
      expect(spool.storageLocation, 'Szafa');
    });

    test('liczby tolerują string i num; brak materiału → Unknown', () {
      final spool = Spool.fromNative({
        'id': '12',
        'material': '   ',
        'label_weight': '1000',
        'weight_used': 250,
      });

      expect(spool.id, 12);
      expect(spool.material, 'Unknown');
      expect(spool.labelWeight, 1000);
      expect(spool.weightUsed, 250);
    });
  });

  group('Spool.fromSpoolman', () {
    test('czyta kształt znormalizowany przez bambuddy', () {
      // Tak wygląda odpowiedź /spoolman/inventory/spools: serwer mapuje szpulę
      // Spoolmana na kształt natywny, zanim dojdzie do apki.
      final spool = Spool.fromSpoolman({
        'id': 31,
        'material': 'PLA',
        'subtype': 'Matte',
        'color_name': 'Ivory White',
        'rgba': 'FFFFFFFF',
        'brand': 'Bambu Lab',
        'label_weight': 1000,
        'weight_used': 250.0,
        'core_weight': 212,
        'cost_per_kg': 24.5,
        'storage_location': 'Regał A',
        'note': 'z Spoolmana',
        'nozzle_temp_min': 190,
        'archived_at': null,
        'data_origin': 'spoolman',
        'k_profiles': const [],
      });

      expect(spool.id, 31);
      expect(spool.displayName, 'Bambu Lab PLA Matte');
      expect(spool.remainingWeight, 750);
      expect(spool.coreWeight, 212);
      expect(spool.costPerKg, 24.5);
      expect(spool.storageLocation, 'Regał A');
      expect(spool.nozzleTempMin, 190);
      expect(spool.isArchived, isFalse);
    });

    test('surowy rekord Spoolmana nadal się parsuje', () {
      final spool = Spool.fromSpoolman({
        'id': 4,
        'used_weight': 120,
        'location': 'Piwnica',
        'comment': 'passthrough',
        'filament': {
          'material': 'PETG',
          'name': 'PETG HF',
          'color_hex': '00FF00',
          'weight': 1000,
          'spool_weight': 190,
          'price': 19.9,
          'vendor': {'name': 'Sunlu'},
        },
      });

      expect(spool.material, 'PETG');
      expect(spool.brand, 'Sunlu');
      expect(spool.rgba, '00FF00');
      expect(spool.labelWeight, 1000);
      expect(spool.weightUsed, 120);
      expect(spool.coreWeight, 190);
      expect(spool.costPerKg, 19.9);
      expect(spool.storageLocation, 'Piwnica');
      expect(spool.note, 'passthrough');
    });
  });

  group('Spool getters', () {
    Spool spool({int label = 1000, double used = 0, int? threshold}) =>
        Spool(
          id: 1,
          material: 'PLA',
          labelWeight: label,
          weightUsed: used,
          lowStockThresholdPct: threshold,
        );

    test('remainingWeight nie schodzi poniżej zera', () {
      expect(spool(label: 1000, used: 1200).remainingWeight, 0);
      expect(spool(label: 1000, used: 650).remainingWeight, 350);
    });

    test('remainingFraction null gdy nie znamy wagi etykiety', () {
      expect(spool(label: 0).remainingFraction, isNull);
      expect(spool(label: 1000, used: 750).remainingFraction, 0.25);
    });

    test('isLowStock wg progu serwera, domyślnie 10%', () {
      // 70 g / 1000 g = 7% ≤ 10% (domyślny próg)
      expect(spool(label: 1000, used: 930).isLowStock, isTrue);
      // 200 g / 1000 g = 20% > 10%
      expect(spool(label: 1000, used: 800).isLowStock, isFalse);
      // próg serwera 25% → 20% poniżej
      expect(spool(label: 1000, used: 800, threshold: 25).isLowStock, isTrue);
    });

    test('isArchived po niepustym archived_at', () {
      expect(
        Spool.fromNative({'id': 1, 'material': 'PLA', 'archived_at': ''})
            .isArchived,
        isFalse,
      );
      expect(
        Spool.fromNative(
                {'id': 1, 'material': 'PLA', 'archived_at': '2026-06-01'})
            .isArchived,
        isTrue,
      );
    });
  });

  group('SpoolAssignment — slot vs szpula zewnętrzna', () {
    SpoolAssignment assign(int amsId, {int trayId = 0}) =>
        SpoolAssignment(
          spoolId: 1,
          printerId: 1,
          amsId: amsId,
          trayId: trayId,
        );

    test('zwykły slot AMS: nie jest zewnętrzny, label AMS·tray+1', () {
      final a = assign(0, trayId: 1);
      expect(a.isExternalSpool, isFalse);
      expect(a.extruder, isNull);
      expect(a.slotLabel, 'AMS0 · 2');
    });

    test('ams_label z serwera ma pierwszeństwo', () {
      const a = SpoolAssignment(
        spoolId: 1,
        printerId: 1,
        amsId: 0,
        trayId: 0,
        amsLabel: 'AMS A',
      );
      expect(a.slotLabel, 'AMS A');
    });

    test('szpula zewnętrzna: ams=255, rozróżnia tray_id (0→lewy, 1→prawy)', () {
      // Zweryfikowane na żywo na X2D z surowych przypisań: OBIE szpule zewnętrzne
      // mają ams_id=255, ekstruder rozróżnia tray_id. TPU tray=0 = lewy (1),
      // PLA tray=1 = prawy (0). Konwencja jak printer_status: 1=lewy, 0=prawy.
      expect(assign(255, trayId: 0).isExternalSpool, isTrue);
      expect(assign(255, trayId: 0).extruder, 1);
      expect(assign(255, trayId: 1).extruder, 0);
    });
  });
}
