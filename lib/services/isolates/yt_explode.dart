import 'dart:async';
import 'dart:isolate';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// A Isolate wrapper for the YoutubeExplode class
/// It contains methods that are computationally expensive
class IsolatedYoutubeExplode {
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;

  IsolatedYoutubeExplode._(
    Isolate isolate,
    ReceivePort receivePort,
    SendPort sendPort,
  )   : _isolate = isolate,
        _receivePort = receivePort,
        _sendPort = sendPort;

  static IsolatedYoutubeExplode? _instance;

  static IsolatedYoutubeExplode get instance => _instance!;

  static bool get isInitialized => _instance != null;

  static Future<void> initialize() async {
    if (_instance != null) {
      return;
    }

    final completer = Completer<SendPort>();

    final receivePort = ReceivePort();

    /// Listen for the main isolate to set the main port
    final subscription = receivePort.listen((message) {
      if (message is SendPort) {
        completer.complete(message);
      }
    });

    final isolate = await Isolate.spawn(_isolateEntry, receivePort.sendPort);

    _instance = IsolatedYoutubeExplode._(
      isolate,
      receivePort,
      await completer.future,
    );

    if (completer.isCompleted) {
      subscription.cancel();
    }
  }

  static void _isolateEntry(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    final youtubeExplode = YoutubeExplode();

    /// Send the main port to the main isolate
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      final SendPort replyPort = message[0];
      final String methodName = message[1];
      final List<dynamic> arguments = message[2];

      // Run the requested method on YoutubeExplode
      var result = switch (methodName) {
        "search" => youtubeExplode.search
            .search(arguments[0] as String, filter: TypeFilters.video)
            .then((s) => s.toList()),
        "video" => youtubeExplode.videos.get(arguments[0] as String),
        "manifest" => youtubeExplode.videos.streamsClient.getManifest(
            arguments[0] as String,
            requireWatchPage: false,
            ytClients: [
              YoutubeApiClient.mediaConnect,
              YoutubeApiClient.ios,
              YoutubeApiClient.android,
              YoutubeApiClient.mweb,
              YoutubeApiClient.tv,
            ],
          ),
        _ => throw ArgumentError('Invalid method name: $methodName'),
      };

      replyPort.send(await result);
    });
  }

  Future<T> _runMethod<T>(String methodName, List<dynamic> args) {
    final completer = Completer<T>();
    final responsePort = ReceivePort();

    responsePort.listen((message) {
      completer.complete(message as T);
      responsePort.close();
    });

    _sendPort.send([responsePort.sendPort, methodName, args]);
    return completer.future;
  }

  Future<List<Video>> search(String query) async {
    return _runMethod<List<Video>>("search", [query]);
  }

  Future<Video> video(String videoId) async {
    return _runMethod<Video>("video", [videoId]);
  }

  Future<StreamManifest> manifest(String videoId) async {
    return _runMethod<StreamManifest>("manifest", [videoId]);
  }

  void dispose() {
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}
