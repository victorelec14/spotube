import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/audio_player/audio_player_streams.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/provider/user_preferences/default_download_dir_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/provider/window_manager/window_manager.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:window_manager/window_manager.dart';

import '../create_container.dart';
import '../mocks/audio_player_listeners_mock.dart';
import '../mocks/window_manager_mock.dart';

List<Override> _createDefaultOverrides() => [
      databaseProvider.overrideWith(
        (ref) {
          final database = AppDatabase(NativeDatabase.memory());

          ref.onDispose(database.close);
          return database;
        },
      ),
      audioPlayerStreamListenersProvider.overrideWith(
        (ref) {
          final streamListeners = MockAudioPlayerStreamListeners();

          when(() => streamListeners.updatePalette()).thenReturn(
            Future.value(),
          );

          return streamListeners;
        },
      ),
      defaultDownloadDirectoryProvider.overrideWith(
        (ref) {
          return Future.value("/storage/emulated/0/Download/Spotube");
        },
      )
    ];

void main() {
  group('UserPreferences', () {
    setUpAll(() {
      registerFallbackValue(TitleBarStyle.normal);
      AppLogger.initialize(false);
    });

    test('Initial value should be equal the default values', () {
      final ref = createContainer(overrides: _createDefaultOverrides());

      final preferences = ref.read(userPreferencesProvider);
      final defaultPreferences = PreferencesTable.defaults();

      expect(preferences, defaultPreferences);
    });

    test('[setSystemTitleBar] should update UI titlebar', () async {
      TestWidgetsFlutterBinding.ensureInitialized();

      final ref = createContainer(overrides: [
        ..._createDefaultOverrides(),
        windowManagerProvider.overrideWith(
          (ref) {
            final mockWindowManager = MockWindowManager();

            when(() => mockWindowManager.setTitleBarStyle(any()))
                .thenAnswer((_) => Future.value());

            return mockWindowManager;
          },
        )
      ]);

      final db = ref.read(databaseProvider);
      final preferences = ref.read(userPreferencesProvider);
      await Future.delayed(const Duration(milliseconds: 300));
      final preferencesNotifier = ref.read(userPreferencesProvider.notifier);

      expect(preferences.systemTitleBar, false);

      await preferencesNotifier.setSystemTitleBar(true);

      final completer = Completer<bool>();
      final subscription = (db.select(db.preferencesTable)
            ..where((tbl) => tbl.id.equals(0)))
          .watchSingle()
          .listen((event) {
        completer.complete(event.systemTitleBar);
      });

      addTearDown(() {
        subscription.cancel();
      });

      final systemTitleBar = await completer.future;

      expect(systemTitleBar, true);
      verify(
        () => ref
            .read(windowManagerProvider)
            .setTitleBarStyle(TitleBarStyle.normal),
      ).called(1);
    });
  });
}
