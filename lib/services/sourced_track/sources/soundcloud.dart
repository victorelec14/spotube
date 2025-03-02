import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotify/spotify.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/song_link/song_link.dart';
import 'package:spotube/services/sourced_track/enums.dart';
import 'package:spotube/services/sourced_track/exceptions.dart';
import 'package:spotube/services/sourced_track/models/source_info.dart';
import 'package:spotube/services/sourced_track/models/source_map.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:soundcloud_explode_dart/soundcloud_explode_dart.dart'
    as soundcloud;

final soundcloudProvider = Provider<soundcloud.SoundcloudClient>(
  (ref) {
    return soundcloud.SoundcloudClient();
  },
);

class SoundcloudSourceInfo extends SourceInfo {
  SoundcloudSourceInfo({
    required super.id,
    required super.title,
    required super.artist,
    required super.thumbnail,
    required super.pageUrl,
    required super.duration,
    required super.artistUrl,
    required super.album,
  });
}

class SoundcloudSourcedTrack extends SourcedTrack {
  SoundcloudSourcedTrack({
    required super.ref,
    required super.source,
    required super.siblings,
    required super.sourceInfo,
    required super.track,
  });

  static Future<SourcedTrack> fetchFromTrack({
    required Track track,
    required Ref ref,
  }) async {
    // Indicates a stream url refresh
    if (track is SoundcloudSourcedTrack) {
      final manifest = await ref
          .read(soundcloudProvider)
          .tracks
          .getStreams(int.parse(track.sourceInfo.id));

      return SoundcloudSourcedTrack(
        ref: ref,
        siblings: track.siblings,
        source: toSourceMap(manifest),
        sourceInfo: track.sourceInfo,
        track: track,
      );
    }

    final database = ref.read(databaseProvider);
    final cachedSource = await (database.select(database.sourceMatchTable)
          ..where((s) => s.trackId.equals(track.id!))
          ..limit(1)
          ..orderBy([
            (s) =>
                OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc),
          ]))
        .getSingleOrNull();
    final soundcloudClient = ref.read(soundcloudProvider);

    if (cachedSource == null ||
        cachedSource.sourceType != SourceType.soundcloud) {
      final siblings = await fetchSiblings(ref: ref, track: track);
      if (siblings.isEmpty) {
        throw TrackNotFoundError(track);
      }

      await database.into(database.sourceMatchTable).insert(
            SourceMatchTableCompanion.insert(
              trackId: track.id!,
              sourceId: siblings.first.info.id,
              sourceType: const Value(SourceType.soundcloud),
            ),
          );

      return SoundcloudSourcedTrack(
        ref: ref,
        siblings: siblings.map((s) => s.info).skip(1).toList(),
        source: siblings.first.source as SourceMap,
        sourceInfo: siblings.first.info,
        track: track,
      );
    } else {
      final details = await soundcloudClient.tracks.get(
        int.parse(cachedSource.sourceId),
      );
      final streams = await soundcloudClient.tracks.getStreams(
        int.parse(cachedSource.sourceId),
      );

      return SoundcloudSourcedTrack(
        ref: ref,
        siblings: [],
        source: toSourceMap(streams),
        sourceInfo: SoundcloudSourceInfo(
          id: details.id.toString(),
          artist: details.user.username,
          artistUrl: details.user.permalinkUrl.toString(),
          pageUrl: details.permalinkUrl.toString(),
          thumbnail: details.artworkUrl.toString(),
          title: details.title,
          duration: Duration(seconds: details.duration.toInt()),
          album: null,
        ),
        track: track,
      );
    }
  }

  static SourceMap toSourceMap(List<soundcloud.StreamInfo> manifest) {
    final m4a = manifest
        .where((audio) => audio.container == soundcloud.Container.mp3)
        .sorted((a, b) {
      return a.quality == soundcloud.Quality.highQuality ? 1 : -1;
    });

    final weba = manifest
        .where((audio) => audio.container == soundcloud.Container.ogg)
        .sorted((a, b) {
      return a.quality == soundcloud.Quality.highQuality ? 1 : -1;
    });

    return SourceMap(
      m4a: SourceQualityMap(
        high: m4a.first.url.toString(),
        medium: (m4a.elementAtOrNull(m4a.length ~/ 2) ?? m4a[1]).url.toString(),
        low: m4a.last.url.toString(),
      ),
      weba: weba.isNotEmpty
          ? SourceQualityMap(
              high: weba.first.url.toString(),
              medium: (weba.elementAtOrNull(weba.length ~/ 2) ?? weba[1])
                  .url
                  .toString(),
              low: weba.last.url.toString(),
            )
          : null,
    );
  }

  static Future<SiblingType> toSiblingType(
    int index,
    soundcloud.Track item,
    soundcloud.SoundcloudClient soundcloudClient,
  ) async {
    SourceMap? sourceMap;
    if (index == 0) {
      final manifest = await soundcloudClient.tracks.getStreams(item.id);
      sourceMap = toSourceMap(manifest);
    }

    final SiblingType sibling = (
      info: SoundcloudSourceInfo(
        id: item.id.toString(),
        artist: item.user.username,
        artistUrl: item.user.permalinkUrl.toString(),
        pageUrl: item.permalinkUrl.toString(),
        thumbnail: item.artworkUrl.toString(),
        title: item.title,
        duration: Duration(seconds: item.duration.toInt()),
        album: null,
      ),
      source: sourceMap,
    );

    return sibling;
  }

  static Future<List<SiblingType>> fetchSiblings({
    required Track track,
    required Ref ref,
  }) async {
    final soundcloudClient = ref.read(soundcloudProvider);

    final links = await SongLinkService.links(track.id!);
    final soundcloudLink =
        links.firstWhereOrNull((link) => link.platform == "soundcloud");

    if (soundcloudLink != null && track is! SourcedTrack) {
      try {
        final details =
            await soundcloudClient.tracks.getByUrl(soundcloudLink.url!);

        return [
          await toSiblingType(
            0,
            details,
            soundcloudClient,
          )
        ];
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    }

    final query = SourcedTrack.getSearchTerm(track);

    final searchResults = await soundcloudClient.search
        .getTracks(query, offset: 0, limit: 10)
        .toList()
        .then((value) => value.expand((e) => e).toList());

    return await Future.wait(
      searchResults.mapIndexed(
        (i, r) => toSiblingType(
          i,
          soundcloud.Track(
            id: r.id,
            title: r.title,
            duration: r.duration,
            user: r.user,
            artworkUrl: r.artworkUrl,
            permalinkUrl: r.permalinkUrl,
            caption: r.caption,
            commentCount: r.commentCount,
            createdAt: r.createdAt,
            description: r.description,
            downloadCount: r.downloadCount,
            genre: r.genre,
            commentable: r.commentable,
            fullDuration: r.fullDuration,
            labelName: r.labelName,
            lastModified: r.lastModified,
            license: r.license,
            likesCount: r.likesCount,
            monetizationModel: r.monetizationModel,
            playbackCount: r.playbackCount,
            policy: r.policy,
            purchaseTitle: r.purchaseTitle,
            purchaseUrl: r.purchaseUrl,
            repostsCount: r.repostsCount,
            tagList: r.tagList,
            waveformUrl: r.waveformUrl,
          ),
          soundcloudClient,
        ),
      ),
    );
  }

  @override
  Future<SourcedTrack> copyWithSibling() async {
    if (siblings.isNotEmpty) {
      return this;
    }
    final fetchedSiblings = await fetchSiblings(ref: ref, track: this);

    return SoundcloudSourcedTrack(
      ref: ref,
      siblings: fetchedSiblings
          .where((s) => s.info.id != sourceInfo.id)
          .map((s) => s.info)
          .toList(),
      source: source,
      sourceInfo: sourceInfo,
      track: this,
    );
  }

  @override
  Future<SourcedTrack?> swapWithSibling(SourceInfo sibling) async {
    if (sibling.id == sourceInfo.id) {
      return null;
    }

    // a sibling source that was fetched from the search results
    final isStepSibling = siblings.none((s) => s.id == sibling.id);

    final newSourceInfo = isStepSibling
        ? sibling
        : siblings.firstWhere((s) => s.id == sibling.id);
    final newSiblings = siblings.where((s) => s.id != sibling.id).toList()
      ..insert(0, sourceInfo);

    final soundcloudClient = ref.read(soundcloudProvider);

    final manifest = await soundcloudClient.tracks.getStreams(
      int.parse(newSourceInfo.id),
    );

    final database = ref.read(databaseProvider);
    await database.into(database.sourceMatchTable).insert(
          SourceMatchTableCompanion.insert(
            trackId: id!,
            sourceId: newSourceInfo.id,
            sourceType: const Value(SourceType.soundcloud),
            // Because we're sorting by createdAt in the query
            // we have to update it to indicate priority
            createdAt: Value(DateTime.now()),
          ),
          mode: InsertMode.replace,
        );

    return SoundcloudSourcedTrack(
      ref: ref,
      siblings: newSiblings,
      source: toSourceMap(manifest),
      sourceInfo: newSourceInfo,
      track: this,
    );
  }
}
