import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotube/utils/platform.dart';

final defaultDownloadDirectoryProvider = FutureProvider<String>((ref) async {
  if (kIsAndroid) return "/storage/emulated/0/Download/Spotube";

  if (kIsMacOS) {
    return join((await getLibraryDirectory()).path, "Caches");
  }

  return getDownloadsDirectory().then((dir) {
    return join(dir!.path, "Spotube");
  });
});
