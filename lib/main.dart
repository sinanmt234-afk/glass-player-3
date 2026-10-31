import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart' as svc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ───────────────────────── Globals ─────────────────────────

final navKey = GlobalKey<NavigatorState>();
const platform = MethodChannel('glass/native');
late final SharedPreferences prefs;
late final Player player;
late final VideoController videoController;
late final PlayerHandler audioHandler;
final ValueNotifier<bool> inPip = ValueNotifier(false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  player = Player();
  videoController = VideoController(player);
  Engine.init();
  audioHandler = await svc.AudioService.init(
    builder: () => PlayerHandler(),
    config: const svc.AudioServiceConfig(
      androidNotificationChannelId: 'com.aetherial.glass_player.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
    ),
  );
  platform.setMethodCallHandler(_onNative);
  platform.invokeMethod('askNotif');
  runApp(const GlassApp());
}

Future<dynamic> _onNative(MethodCall c) async {
  if (c.method == 'pip') inPip.value = c.arguments == true;
  if (c.method == 'newIntent') {
    await Engine.play([itemFromMap(c.arguments as Map)], 0);
    openPlayer();
  }
}

// ───────────────────────── Models / helpers ─────────────────────────

class Item {
  const Item({required this.path, required this.title, required this.audio, this.durationSec = 0});
  final String path;
  final String title;
  final bool audio;
  final int durationSec;

  Map<String, dynamic> toJson() => {'path': path, 'title': title, 'audio': audio, 'dur': durationSec};
  factory Item.fromJson(Map<String, dynamic> j) =>
      Item(path: j['path'], title: j['title'], audio: j['audio'] == true, durationSec: (j['dur'] ?? 0) as int);
}

bool isAudioName(String n) {
  final e = n.split('.').last.toLowerCase();
  return const {'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'amr', 'mka', 'ac3', 'alac'}.contains(e);
}

Item itemFromMap(Map m) {
  final name = (m['name'] as String?) ?? 'Media';
  final mime = (m['mime'] as String?) ?? '';
  return Item(
    path: m['path'] as String,
    title: name,
    audio: mime.startsWith('audio') || (mime.isEmpty && isAudioName(name)),
  );
}

String fmt(Duration d) {
  String t(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${t(m)}:${t(s)}' : '${t(m)}:${t(s)}';
}

Future<List<Map>> pickFiles(List<String> mimes, bool multi) async {
  final r = await platform.invokeMethod<List<dynamic>>('pick', {'mimes': mimes, 'multiple': multi});
  return (r ?? []).map((e) => Map<dynamic, dynamic>.from(e as Map)).toList();
}

bool _playerShown = false;
void openPlayer() {
  if (_playerShown) return;
  _playerShown = true;
  navKey.currentState
      ?.push(PageRouteBuilder(
        pageBuilder: (_, __, ___) => const PlayerPage(),
        transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      ))
      .then((_) => _playerShown = false);
}

// ───────────────────────── Playback engine ─────────────────────────

class Engine {
  static List<Item> queue = [];
  static final current = ValueNotifier<Item?>(null);
  static final recentTick = ValueNotifier<int>(0);
  static int _lastIndex = -1;
  static int _lastSave = 0;
  static bool _resuming = false;

  static void init() {
    player.stream.playlist.listen((p) {
      if (p.medias.isEmpty || p.index < 0 || p.index >= p.medias.length) return;
      if (p.index == _lastIndex) return;
      _lastIndex = p.index;
      final key = p.medias[p.index].extras?['p'];
      Item? found;
      for (final e in queue) {
        if (e.path == key) {
          found = e;
          break;
        }
      }
      if (found == null) return;
      current.value = found;
      _onStart(found);
    });
    player.stream.position.listen((pos) {
      final it = current.value;
      if (it == null || _resuming) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSave > 3000) {
        _lastSave = now;
        _save(it, pos);
      }
    });
    player.stream.playing.listen((p) {
      final it = current.value;
      if (it != null && !p && !_resuming) _save(it, player.state.position);
    });
  }

  static void _save(Item it, Duration pos) {
    final d = player.state.duration.inMilliseconds;
    if (d > 0 && pos.inMilliseconds > d - 8000) {
      prefs.remove('pos:${it.path}');
    } else {
      prefs.setInt('pos:${it.path}', pos.inMilliseconds);
    }
    if (d > 0) prefs.setInt('dur:${it.path}', d);
  }

  static Future<void> _onStart(Item it) async {
    _addRecent(it);
    final saved = prefs.getInt('pos:${it.path}') ?? 0;
    if (saved <= 5000) return;
    _resuming = true;
    try {
      await Future.delayed(const Duration(milliseconds: 250));
      for (var i = 0; i < 30; i++) {
        if (player.state.duration > Duration.zero) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      final d = player.state.duration.inMilliseconds;
      if (d > 0 && saved < d - 8000 && current.value?.path == it.path) {
        await player.seek(Duration(milliseconds: saved));
      }
    } catch (_) {}
    _resuming = false;
  }

  static void _addRecent(Item it) {
    final ok = (it.path.startsWith('/') && !it.path.startsWith('/proc/')) || it.path.startsWith('http');
    if (!ok) return;
    final list = prefs.getStringList('recent') ?? [];
    list.removeWhere((s) => (jsonDecode(s) as Map)['path'] == it.path);
    list.insert(0, jsonEncode(it.toJson()));
    if (list.length > 30) list.removeRange(30, list.length);
    prefs.setStringList('recent', list);
    recentTick.value++;
  }

  static List<Item> recents() => (prefs.getStringList('recent') ?? [])
      .map((s) => Item.fromJson(Map<String, dynamic>.from(jsonDecode(s) as Map)))
      .toList();

  static Future<void> play(List<Item> items, int index) async {
    if (items.isEmpty) return;
    queue = items;
    _lastIndex = -1;
    current.value = items[index];
    await player.open(Playlist(
      items.map((e) => Media(e.path, extras: {'p': e.path})).toList(),
      index: index,
    ));
  }
}

class PlayerHandler extends svc.BaseAudioHandler with svc.SeekHandler {
  PlayerHandler() {
    player.stream.playing.listen((_) => _push());
    player.stream.buffering.listen((_) => _push());
    player.stream.completed.listen((_) => _push());
    Engine.current.addListener(_meta);
  }

  void _meta() {
    final it = Engine.current.value;
    if (it == null) return;
    mediaItem.add(svc.MediaItem(
      id: it.path,
      title: it.title,
      duration: it.durationSec > 0 ? Duration(seconds: it.durationSec) : null,
    ));
    _push();
  }

  void _push() {
    final playing = player.state.playing;
    playbackState.add(svc.PlaybackState(
      controls: [
        svc.MediaControl.skipToPrevious,
        playing ? svc.MediaControl.pause : svc.MediaControl.play,
        svc.MediaControl.skipToNext,
        svc.MediaControl.stop,
      ],
      systemActions: const {svc.MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState:
          player.state.buffering ? svc.AudioProcessingState.buffering : svc.AudioProcessingState.ready,
      playing: playing,
      updatePosition: player.state.position,
      speed: player.state.rate,
    ));
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> skipToNext() => player.next();
  @override
  Future<void> skipToPrevious() => player.previous();
  @override
  Future<void> stop() async {
    await player.stop();
    Engine.current.value = null;
    return super.stop();
  }
}

// ───────────────────────── Theme + glass widgets ─────────────────────────

ThemeData _theme(Brightness b) => ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6C8CFF), brightness: b),
      scaffoldBackgroundColor: Colors.transparent,
    );

class GlassApp extends StatelessWidget {
  const GlassApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey,
      debugShowCheckedModeBanner: false,
      title: 'Glass Player',
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      builder: (c, child) => Stack(
        fit: StackFit.expand,
        children: [const GlassBackground(), if (child != null) child],
      ),
      home: const HomePage(),
    );
  }
}

class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, this.forceDark = false});
  final bool forceDark;

  Widget _blob(double size, Color c, {double? top, double? left, double? right, double? bottom}) => Positioned(
        top: top,
        left: left,
        right: right,
        bottom: bottom,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [c, c.withOpacity(0)]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final dark = forceDark || Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xFF0B1020), Color(0xFF1A1033), Color(0xFF071A2B)]
                  : const [Color(0xFFEAF1FF), Color(0xFFF4E9FF), Color(0xFFE3F6FF)],
            ),
          ),
        ),
        _blob(340, dark ? const Color(0x886C5CFF) : const Color(0x886C8CFF), top: -90, left: -80),
        _blob(300, dark ? const Color(0x77FF4FA3) : const Color(0x77FF8FC5), top: 220, right: -120),
        _blob(360, dark ? const Color(0x7700C2FF) : const Color(0x7766DDFF), bottom: -120, left: -60),
      ],
    );
  }
}

class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 24, this.padding, this.blur = 22, this.onTap});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final br = BorderRadius.circular(radius);
    Widget w = ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: br,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(dark ? 0.18 : 0.62),
                Colors.white.withOpacity(dark ? 0.06 : 0.26),
              ],
            ),
            border: Border.all(color: Colors.white.withOpacity(dark ? 0.30 : 0.80), width: 1.2),
          ),
          child: child,
        ),
      ),
    );
    if (onTap != null) {
      w = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: w);
    }
    return w;
  }
}

Widget header(BuildContext c, String t, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Row(children: [
        Expanded(
          child: Text(t,
              style: Theme.of(c).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (trailing != null) trailing,
      ]),
    );

// ───────────────────────── Library ─────────────────────────

class Library {
  static Future<bool> ensure() async {
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.hasAccess;
  }

  static Future<void> playFrom(List<AssetEntity> assets, int tapped) async {
    final files = await Future.wait(assets.map((a) => a.file));
    final items = <Item>[];
    var idx = 0;
    for (var i = 0; i < assets.length; i++) {
      final f = files[i];
      if (f == null) continue;
      if (i == tapped) idx = items.length;
      items.add(Item(
        path: f.path,
        title: assets[i].title ?? f.path.split('/').last,
        audio: assets[i].type == AssetType.audio,
        durationSec: assets[i].duration,
      ));
    }
    if (items.isEmpty) return;
    await Engine.play(items, idx);
    openPlayer();
  }
}

class Thumb extends StatefulWidget {
  const Thumb({super.key, required this.asset});
  final AssetEntity asset;
  @override
  State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  late final Future<Uint8List?> f = widget.asset.thumbnailDataWithSize(const ThumbnailSize(240, 160));
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: f,
      builder: (c, s) => s.data == null
          ? const Center(child: Icon(Icons.movie_rounded))
          : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

class MediaTile extends StatelessWidget {
  const MediaTile({super.key, required this.asset, required this.onTap});
  final AssetEntity asset;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Glass(
        radius: 20,
        padding: const EdgeInsets.all(8),
        onTap: onTap,
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 104,
              height: 64,
              child: asset.type == AssetType.video
                  ? Thumb(asset: asset)
                  : const Center(child: Icon(Icons.music_note_rounded, size: 30)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(asset.title ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(fmt(Duration(seconds: asset.duration)), style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      ),
    );
  }
}

class PermissionCard extends StatelessWidget {
  const PermissionCard({super.key, required this.onGrant});
  final Future<void> Function() onGrant;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Glass(
          radius: 28,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_open_rounded, size: 40),
            const SizedBox(height: 12),
            const Text('Allow access to your videos and music', textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                final ps = await PhotoManager.requestPermissionExtend();
                if (!ps.hasAccess) {
                  await PhotoManager.openSetting();
                } else {
                  await onGrant();
                }
              },
              child: const Text('Grant access'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── Home ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final m = await platform.invokeMethod('initial');
        if (m != null) {
          await Engine.play([itemFromMap(m as Map)], 0);
          openPlayer();
        }
      } catch (_) {}
    });
  }

  Widget _navItem(IconData icon, String label, int i) {
    final sel = tab == i;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => tab = i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: sel ? Theme.of(context).colorScheme.primary.withOpacity(0.25) : Colors.transparent,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 24),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        SafeArea(
          bottom: false,
          child: IndexedStack(index: tab, children: const [VideosTab(), AudioTab(), MoreTab()]),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const MiniPlayer(),
                const SizedBox(height: 8),
                Glass(
                  radius: 32,
                  padding: const EdgeInsets.all(6),
                  child: Row(children: [
                    _navItem(Icons.video_library_rounded, 'Videos', 0),
                    _navItem(Icons.library_music_rounded, 'Music', 1),
                    _navItem(Icons.folder_open_rounded, 'More', 2),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Item?>(
      valueListenable: Engine.current,
      builder: (c, it, _) {
        if (it == null) return const SizedBox.shrink();
        return Glass(
          radius: 26,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          onTap: openPlayer,
          child: Row(children: [
            Icon(it.audio ? Icons.music_note_rounded : Icons.play_circle_outline_rounded),
            const SizedBox(width: 10),
            Expanded(child: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: player.state.playing,
              builder: (c, s) => IconButton(
                icon: Icon(s.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded),
                onPressed: () => player.playOrPause(),
              ),
            ),
            IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => audioHandler.stop()),
          ]),
        );
      },
    );
  }
}

class VideosTab extends StatefulWidget {
  const VideosTab({super.key});
  @override
  State<VideosTab> createState() => _VideosTabState();
}

class _VideosTabState extends State<VideosTab> {
  List<AssetPathEntity> paths = [];
  List<int> counts = [];
  bool loading = true, denied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ok = await Library.ensure();
    if (!ok) {
      if (mounted) setState(() { denied = true; loading = false; });
      return;
    }
    final ps = await PhotoManager.getAssetPathList(type: RequestType.video);
    final cs = await Future.wait(ps.map((p) => p.assetCountAsync));
    final fp = <AssetPathEntity>[];
    final fc = <int>[];
    for (var i = 0; i < ps.length; i++) {
      if (cs[i] > 0) {
        fp.add(ps[i]);
        fc.add(cs[i]);
      }
    }
    if (!mounted) return;
    setState(() { paths = fp; counts = fc; denied = false; loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (denied) {
      body = PermissionCard(onGrant: _load);
    } else if (paths.isEmpty) {
      body = const Center(child: Text('No videos found'));
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 200),
          itemCount: paths.length,
          itemBuilder: (c, i) {
            final p = paths[i];
            final name = p.isAll ? 'All videos' : p.name;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                radius: 22,
                padding: const EdgeInsets.all(14),
                onTap: () => Navigator.push(
                    c, MaterialPageRoute(builder: (_) => FolderPage(path: p, title: name))),
                child: Row(children: [
                  const Icon(Icons.folder_rounded, size: 34),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      Text('${counts[i]} videos', style: Theme.of(c).textTheme.bodySmall),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ]),
              ),
            );
          },
        ),
      );
    }
    return Column(children: [header(context, 'Videos'), Expanded(child: body)]);
  }
}

class FolderPage extends StatefulWidget {
  const FolderPage({super.key, required this.path, required this.title});
  final AssetPathEntity path;
  final String title;
  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  List<AssetEntity>? assets;
  @override
  void initState() {
    super.initState();
    widget.path.getAssetListPaged(page: 0, size: 3000).then((v) {
      if (mounted) setState(() => assets = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = assets;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.title),
      ),
      body: a == null
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 40),
              itemCount: a.length,
              itemBuilder: (c, i) => MediaTile(asset: a[i], onTap: () => Library.playFrom(a, i)),
            ),
    );
  }
}

class AudioTab extends StatefulWidget {
  const AudioTab({super.key});
  @override
  State<AudioTab> createState() => _AudioTabState();
}

class _AudioTabState extends State<AudioTab> {
  List<AssetEntity> assets = [];
  bool loading = true, denied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ok = await Library.ensure();
    if (!ok) {
      if (mounted) setState(() { denied = true; loading = false; });
      return;
    }
    final ps = await PhotoManager.getAssetPathList(type: RequestType.audio);
    var list = <AssetEntity>[];
    if (ps.isNotEmpty) {
      final all = ps.firstWhere((p) => p.isAll, orElse: () => ps.first);
      list = await all.getAssetListPaged(page: 0, size: 5000);
    }
    if (!mounted) return;
    setState(() { assets = list; denied = false; loading = false; });
  }

  Widget _btn(IconData i, String t, VoidCallback f) => Glass(
        radius: 22,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        onTap: f,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 20),
          const SizedBox(width: 6),
          Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (denied) {
      body = PermissionCard(onGrant: _load);
    } else if (assets.isEmpty) {
      body = const Center(child: Text('No music found'));
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 200),
          itemCount: assets.length + 1,
          itemBuilder: (c, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(children: [
                  _btn(Icons.play_arrow_rounded, 'Play all', () => Library.playFrom(assets, 0)),
                  const SizedBox(width: 10),
                  _btn(Icons.shuffle_rounded, 'Shuffle', () {
                    final l = [...assets]..shuffle();
                    Library.playFrom(l, 0);
                  }),
                ]),
              );
            }
            return MediaTile(asset: assets[i - 1], onTap: () => Library.playFrom(assets, i - 1));
          },
        ),
      );
    }
    return Column(children: [header(context, 'Music'), Expanded(child: body)]);
  }
}

class MoreTab extends StatefulWidget {
  const MoreTab({super.key});
  @override
  State<MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<MoreTab> {
  Widget _action(IconData i, String t, String sub, VoidCallback f) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Glass(
          radius: 22,
          padding: const EdgeInsets.all(14),
          onTap: f,
          child: Row(children: [
            Icon(i, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                Text(sub, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ]),
        ),
      );

  Future<void> _openFiles() async {
    final r = await pickFiles(['video/*', 'audio/*'], true);
    if (r.isEmpty) return;
    await Engine.play(r.map(itemFromMap).toList(), 0);
    openPlayer();
  }

  Future<void> _openUrl() async {
    final ctl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Network stream'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://… .mp4 / .m3u8 / rtsp://'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Play')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await Engine.play([Item(path: url, title: url.split('/').last, audio: isAudioName(url))], 0);
    openPlayer();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 200),
      children: [
        header(context, 'More'),
        _action(Icons.folder_open_rounded, 'Open file', 'Pick video or audio from anywhere', _openFiles),
        _action(Icons.link_rounded, 'Network stream', 'HTTP, HLS, RTSP link', _openUrl),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Glass(
            radius: 22,
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(children: [
              const Icon(Icons.picture_in_picture_alt_rounded, size: 28),
              const SizedBox(width: 14),
              const Expanded(
                child: Text('Auto Picture-in-Picture when leaving app',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              Switch(
                value: prefs.getBool('autopip') ?? true,
                onChanged: (v) {
                  prefs.setBool('autopip', v);
                  setState(() {});
                },
              ),
            ]),
          ),
        ),
        ValueListenableBuilder<int>(
          valueListenable: Engine.recentTick,
          builder: (c, _, __) {
            final rs = Engine.recents();
            if (rs.isEmpty) return const SizedBox.shrink();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
                child: Text('Continue watching',
                    style: Theme.of(c).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              for (final it in rs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Glass(
                    radius: 20,
                    padding: const EdgeInsets.all(14),
                    onTap: () async {
                      await Engine.play([it], 0);
                      openPlayer();
                    },
                    child: Row(children: [
                      Icon(it.audio ? Icons.music_note_rounded : Icons.play_circle_outline_rounded),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Builder(builder: (_) {
                            final pos = prefs.getInt('pos:${it.path}') ?? 0;
                            final dur = prefs.getInt('dur:${it.path}') ?? 0;
                            if (dur <= 0 || pos <= 0) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: LinearProgressIndicator(
                                value: (pos / dur).clamp(0.0, 1.0).toDouble(),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            );
                          }),
                        ]),
                      ),
                    ]),
                  ),
                ),
            ]);
          },
        ),
      ],
    );
  }
}

// ───────────────────────── Player page ─────────────────────────

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  bool _show = true, _locked = false, _shuffle = false;
  BoxFit _fit = BoxFit.contain;
  Timer? _hide, _osdT;
  String? _osd;
  double _bright = 0.5, _vol = 0.5, _b0 = 0, _v0 = 0, _acc = 0, _prevRate = 1.0, _hAcc = 0;
  bool _leftSide = true;
  Offset _dt = Offset.zero;
  Duration _h0 = Duration.zero;
  Duration? _target;
  double? _drag;
  StreamSubscription? _hSub;
  late final bool _wasAudio;

  bool get _audio => Engine.current.value?.audio ?? false;

  @override
  void initState() {
    super.initState();
    _wasAudio = _audio;
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    if (!_audio) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initLevels();
    _hSub = player.stream.height.listen((_) => _syncPip());
    _syncPip();
    _kick();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _osdT?.cancel();
    _hSub?.cancel();
    platform.invokeMethod('setBrightness', {'v': -1.0});
    platform.invokeMethod('autoPip', {'enabled': false, 'num': 16, 'den': 9});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    if (!_wasAudio) player.pause();
    super.dispose();
  }

  Future<void> _initLevels() async {
    try {
      final b = await platform.invokeMethod<double>('getBrightness') ?? -1;
      final v = await platform.invokeMethod<double>('getVolume') ?? 0.5;
      if (mounted) setState(() { _bright = b < 0 ? 0.5 : b; _vol = v; });
    } catch (_) {}
  }

  void _syncPip() {
    final w = player.state.width, h = player.state.height;
    var r = (w != null && h != null && h > 0) ? w / h : 16 / 9;
    r = r.clamp(0.5, 2.0).toDouble();
    platform.invokeMethod('autoPip', {
      'enabled': !_audio && (prefs.getBool('autopip') ?? true),
      'num': (r * 100).round(),
      'den': 100,
    });
  }

  void _kick() {
    _hide?.cancel();
    if (!_show) setState(() => _show = true);
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && player.state.playing && !_audio) setState(() => _show = false);
    });
  }

  void _toggle() {
    if (_show) {
      setState(() => _show = false);
    } else {
      _kick();
    }
  }

  void _osdShow(String t) {
    _osdT?.cancel();
    setState(() => _osd = t);
    _osdT = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  void _skip(int s) {
    var t = player.state.position + Duration(seconds: s);
    if (t < Duration.zero) t = Duration.zero;
    final d = player.state.duration;
    if (d > Duration.zero && t > d) t = d;
    player.seek(t);
    _osdShow(s > 0 ? '+${s}s' : '${s}s');
  }

  void _rotate() {
    final land = MediaQuery.of(context).orientation == Orientation.landscape;
    SystemChrome.setPreferredOrientations(land
        ? [DeviceOrientation.portraitUp]
        : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    _kick();
  }

  void _cycleFit() {
    setState(() {
      if (_fit == BoxFit.contain) {
        _fit = BoxFit.cover;
        _osd = 'Zoom to fill';
      } else if (_fit == BoxFit.cover) {
        _fit = BoxFit.fill;
        _osd = 'Stretch';
      } else {
        _fit = BoxFit.contain;
        _osd = 'Fit';
      }
    });
    _osdShow(_osd!);
  }

  void _enterPip() {
    final w = player.state.width, h = player.state.height;
    var r = (w != null && h != null && h > 0) ? w / h : 16 / 9;
    r = r.clamp(0.5, 2.0).toDouble();
    platform.invokeMethod('pip', {'num': (r * 100).round(), 'den': 100});
  }

  Future<void> _loadSub() async {
    final r = await pickFiles(['*/*'], false);
    if (r.isEmpty) return;
    await player.setSubtitleTrack(SubtitleTrack.uri(r.first['path'] as String, title: r.first['name'] as String?));
  }

  String _tl(dynamic t) {
    if (t.id == 'auto') return 'Auto';
    if (t.id == 'no') return 'Off';
    final parts = <String>[
      if ((t.title as String?)?.isNotEmpty ?? false) t.title as String,
      if ((t.language as String?)?.isNotEmpty ?? false) t.language as String,
    ];
    return parts.isEmpty ? 'Track ${t.id}' : parts.join(' · ');
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      );

  Widget _opt(String t, bool sel, VoidCallback f) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(t),
        trailing: sel ? const Icon(Icons.check_rounded) : null,
        onTap: f,
      );

  void _tracks() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Glass(
            radius: 28,
            padding: const EdgeInsets.all(18),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
              child: StreamBuilder<Track>(
                stream: player.stream.track,
                initialData: player.state.track,
                builder: (c, ts) {
                  final tr = player.state.tracks;
                  final cur = ts.data ?? player.state.track;
                  return ListView(shrinkWrap: true, children: [
                    _h('Speed'),
                    StreamBuilder<double>(
                      stream: player.stream.rate,
                      initialData: player.state.rate,
                      builder: (c, rs) => Wrap(spacing: 8, children: [
                        for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                          ChoiceChip(
                            label: Text('${r}x'),
                            selected: rs.data == r,
                            onSelected: (_) => player.setRate(r),
                          ),
                      ]),
                    ),
                    _h('Audio track'),
                    for (final t in tr.audio)
                      _opt(_tl(t), cur.audio.id == t.id, () => player.setAudioTrack(t)),
                    _h('Subtitles'),
                    for (final t in tr.subtitle)
                      _opt(_tl(t), cur.subtitle.id == t.id, () => player.setSubtitleTrack(t)),
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.subtitles_rounded),
                      title: const Text('Load subtitle file'),
                      onTap: () {
                        Navigator.pop(c);
                        _loadSub();
                      },
                    ),
                  ]);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── gestures ──

  Widget _gestures(BoxConstraints bc) {
    if (_locked) {
      return GestureDetector(behavior: HitTestBehavior.opaque, onTap: _toggle);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onDoubleTapDown: (d) => _dt = d.localPosition,
      onDoubleTap: () {
        final w = bc.maxWidth;
        if (_dt.dx < w / 3) {
          _skip(-10);
        } else if (_dt.dx > w * 2 / 3) {
          _skip(10);
        } else {
          player.playOrPause();
        }
      },
      onLongPressStart: (_) {
        _prevRate = player.state.rate;
        player.setRate(2.0);
        setState(() => _osd = '2× speed');
      },
      onLongPressEnd: (_) {
        player.setRate(_prevRate);
        setState(() => _osd = null);
      },
      onVerticalDragStart: (d) {
        _leftSide = d.localPosition.dx < bc.maxWidth / 2;
        _b0 = _bright;
        _v0 = _vol;
        _acc = 0;
      },
      onVerticalDragUpdate: (d) {
        _acc -= d.delta.dy / (bc.maxHeight * 0.6);
        if (_leftSide) {
          _bright = (_b0 + _acc).clamp(0.02, 1.0).toDouble();
          platform.invokeMethod('setBrightness', {'v': _bright});
          _osdShow('Brightness ${(_bright * 100).round()}%');
        } else {
          _vol = (_v0 + _acc).clamp(0.0, 1.0).toDouble();
          platform.invokeMethod('setVolume', {'v': _vol});
          _osdShow('Volume ${(_vol * 100).round()}%');
        }
      },
      onHorizontalDragStart: (d) {
        _h0 = player.state.position;
        _hAcc = 0;
        _target = _h0;
      },
      onHorizontalDragUpdate: (d) {
        _hAcc += d.delta.dx;
        var t = _h0 + Duration(milliseconds: (_hAcc * 120).round());
        final dur = player.state.duration;
        if (t < Duration.zero) t = Duration.zero;
        if (dur > Duration.zero && t > dur) t = dur;
        final diff = (t - _h0).inSeconds;
        setState(() {
          _target = t;
          _osd = '${fmt(t)}  (${diff >= 0 ? '+' : '-'}${diff.abs()}s)';
        });
      },
      onHorizontalDragEnd: (_) {
        if (_target != null) player.seek(_target!);
        setState(() {
          _target = null;
          _osd = null;
        });
      },
    );
  }

  // ── controls ──

  Widget _seekBar() {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (c, ps) => StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: player.state.duration,
        builder: (c, ds) {
          final dur = ds.data ?? Duration.zero;
          final max = math.max(1.0, dur.inMilliseconds.toDouble());
          final cur = _drag ?? (_target?.inMilliseconds ?? (ps.data ?? Duration.zero).inMilliseconds).toDouble();
          final v = cur.clamp(0.0, max).toDouble();
          return Row(children: [
            Text(fmt(Duration(milliseconds: v.round())), style: const TextStyle(fontSize: 12)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(c).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  value: v,
                  max: max,
                  onChanged: (x) {
                    setState(() => _drag = x);
                    _kick();
                  },
                  onChangeEnd: (x) {
                    player.seek(Duration(milliseconds: x.round()));
                    setState(() => _drag = null);
                  },
                ),
              ),
            ),
            Text(fmt(dur), style: const TextStyle(fontSize: 12)),
          ]);
        },
      ),
    );
  }

  Widget _ib(IconData i, VoidCallback f, {double size = 26, Color color = Colors.white}) => IconButton(
        icon: Icon(i, size: size, color: color),
        onPressed: () {
          f();
          _kick();
        },
      );

  Widget _mainRow() => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _ib(Icons.skip_previous_rounded, () => player.previous(), size: 32),
        _ib(Icons.replay_10_rounded, () => _skip(-10), size: 30),
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (c, s) => Glass(
            radius: 40,
            onTap: () {
              player.playOrPause();
              _kick();
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(s.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 38, color: Colors.white),
            ),
          ),
        ),
        _ib(Icons.forward_10_rounded, () => _skip(10), size: 30),
        _ib(Icons.skip_next_rounded, () => player.next(), size: 32),
      ]);

  Widget _toolsRow(bool audio) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      StreamBuilder<PlaylistMode>(
        stream: player.stream.playlistMode,
        initialData: player.state.playlistMode,
        builder: (c, s) {
          final m = s.data ?? PlaylistMode.none;
          return _ib(
            m == PlaylistMode.single ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            () => player.setPlaylistMode(m == PlaylistMode.none
                ? PlaylistMode.loop
                : m == PlaylistMode.loop
                    ? PlaylistMode.single
                    : PlaylistMode.none),
            size: 22,
            color: m == PlaylistMode.none ? Colors.white54 : Colors.white,
          );
        },
      ),
      _ib(Icons.shuffle_rounded, () {
        _shuffle = !_shuffle;
        player.setShuffle(_shuffle);
        _osdShow(_shuffle ? 'Shuffle on' : 'Shuffle off');
      }, size: 22, color: _shuffle ? Colors.white : Colors.white54),
      StreamBuilder<double>(
        stream: player.stream.rate,
        initialData: player.state.rate,
        builder: (c, s) => TextButton(
          onPressed: _tracks,
          child: Text('${(s.data ?? 1.0).toString().replaceAll(RegExp(r'\.0$'), '')}x',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ),
      ),
      if (!audio) ...[
        _ib(Icons.aspect_ratio_rounded, _cycleFit, size: 22),
        _ib(Icons.screen_rotation_rounded, _rotate, size: 22),
        _ib(Icons.picture_in_picture_alt_rounded, _enterPip, size: 22),
        _ib(Icons.lock_outline_rounded, () => setState(() => _locked = true), size: 22),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _theme(Brightness.dark),
      child: ValueListenableBuilder<bool>(
        valueListenable: inPip,
        builder: (c, pip, _) => Scaffold(
          backgroundColor: Colors.transparent,
          body: ValueListenableBuilder<Item?>(
            valueListenable: Engine.current,
            builder: (c, item, _) {
              if (item == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && Engine.current.value == null) Navigator.maybePop(context);
                });
                return const ColoredBox(color: Colors.black);
              }
              final audio = item.audio;
              final ui = (_show || audio) && !pip;
              final visible = ui && !_locked;
              return LayoutBuilder(
                builder: (c, bc) => Stack(fit: StackFit.expand, children: [
                  if (audio)
                    const GlassBackground(forceDark: true)
                  else
                    const ColoredBox(color: Colors.black),
                  if (audio)
                    _AudioArt(title: item.title)
                  else
                    Video(
                      controller: videoController,
                      controls: NoVideoControls,
                      fit: _fit,
                      fill: Colors.black,
                      subtitleViewConfiguration: const SubtitleViewConfiguration(
                        style: TextStyle(
                          fontSize: 34,
                          color: Colors.white,
                          backgroundColor: Color(0x99000000),
                        ),
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 56),
                      ),
                    ),
                  if (!audio && !pip) Positioned.fill(child: _gestures(bc)),
                  if (!pip)
                    IgnorePointer(
                      child: StreamBuilder<bool>(
                        stream: player.stream.buffering,
                        initialData: player.state.buffering,
                        builder: (c, s) => s.data == true
                            ? const Center(child: CircularProgressIndicator())
                            : const SizedBox.shrink(),
                      ),
                    ),
                  AnimatedOpacity(
                    opacity: visible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !visible,
                      child: Stack(fit: StackFit.expand, children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Glass(
                                radius: 24,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
                                    onPressed: () => Navigator.maybePop(context),
                                  ),
                                  Expanded(
                                    child: Text(item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: Colors.white, fontWeight: FontWeight.w600)),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.tune_rounded, color: Colors.white),
                                    onPressed: _tracks,
                                  ),
                                ]),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Glass(
                                radius: 28,
                                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  _seekBar(),
                                  _mainRow(),
                                  _toolsRow(audio),
                                ]),
                              ),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  if (_locked && _show && !pip)
                    Positioned(
                      left: 16,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Glass(
                          radius: 30,
                          onTap: () => setState(() => _locked = false),
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Icon(Icons.lock_rounded, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  if (_osd != null && !pip)
                    IgnorePointer(
                      child: Center(
                        child: Glass(
                          radius: 20,
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                          child: Text(_osd!,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AudioArt extends StatelessWidget {
  const _AudioArt({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 150, top: 70),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Glass(
              radius: 110,
              child: SizedBox(
                width: 220,
                height: 220,
                child: Icon(Icons.music_note_rounded, size: 110, color: Colors.white),
              ),
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30),
              child: Text(title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}
