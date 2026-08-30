import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../session/recorder.dart';
import '../settings/identity.dart';
import 'repository.dart';

/// Distinguishes "no network" from "backend responded but not with a 200":
/// the two failure modes read very differently to a player, so the copy
/// shouldn't claim "offline" when the server was in fact reachable.
enum _LeaderboardErrorKind {
  /// No response at all (no connectivity, DNS failure, timeout, ...).
  offline('Classement indisponible hors ligne.'),

  /// The backend responded with a non-200 status ([LeaderboardException]).
  server('Classement momentanément indisponible.');

  const _LeaderboardErrorKind(this.message);
  final String message;
}

_LeaderboardErrorKind _classifyError(Object error) =>
    error is LeaderboardException
        ? _LeaderboardErrorKind.server
        : _LeaderboardErrorKind.offline;

/// Displays the top-50 leaderboard and the player's own rank. Best-effort
/// submits the local total km on open (and on pull-to-refresh) so the
/// backend stays in sync even if the last session's submit failed; the
/// local [TotalDistanceStore] total always remains the source of truth.
///
/// Keeps the last-known-good list visible across a refresh — only the very
/// first load (before any data has ever arrived) shows a full-screen
/// spinner; afterwards [RefreshIndicator] provides its own, without the
/// list being replaced underneath it.
class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  final _totalStore = TotalDistanceStore();
  LeaderboardData? _data;
  _LeaderboardErrorKind? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<LeaderboardData> _submitAndFetch() async {
    final identity = await ref.read(identityStoreProvider).get();
    final repo = ref.read(leaderboardRepositoryProvider);
    try {
      final totalKm = await _totalStore.totalKm();
      await repo.submit(identity, totalKm);
    } catch (_) {
      // Best-effort: submission failures here stay silent — the local
      // total is the source of truth and will be retried on the next
      // session end or the next time this screen opens.
    }
    return repo.fetch(identity.userId);
  }

  Future<void> _load() async {
    try {
      final data = await _submitAndFetch();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _classifyError(e);
        _loading = false;
      });
    }
  }

  /// Pull-to-refresh: deliberately never touches `_loading` / clears `_data`
  /// up front, so the previously-loaded list stays on screen the whole
  /// time — [RefreshIndicator] already shows its own progress affordance.
  Future<void> _refresh() async {
    try {
      final data = await _submitAndFetch();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      final kind = _classifyError(e);
      if (_data == null) {
        // Nothing to keep showing — surface the error state itself.
        setState(() => _error = kind);
      } else {
        // Keep the existing list; just let the player know the refresh
        // failed instead of silently discarding their pulled gesture.
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(kind.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_data == null) {
      body = _buildError(_error!);
    } else {
      body = _buildList(_data!);
    }
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Classement',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _buildError(_LeaderboardErrorKind kind) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 48),
                    const SizedBox(height: 12),
                    Text(kind.message, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _refresh,
                      child: const Text('Réessayer'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(LeaderboardData data) {
    final top = data.top.take(50).toList();
    final me = data.me;
    final meInTop = me != null && top.any((e) => e.rank == me.rank);
    final extraRow = me != null && !meInTop;

    if (top.isEmpty && !extraRow) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.7,
              child: const Center(child: Text('Aucun score pour le moment')),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: top.length + (extraRow ? 1 : 0),
        itemBuilder: (context, index) {
          if (index < top.length) {
            final e = top[index];
            final isMe = me != null && e.rank == me.rank;
            return _entryTile(e, isMe);
          }
          return _entryTile(me!, true);
        },
      ),
    );
  }

  Widget _entryTile(LeaderboardEntry e, bool isMe) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return ListTile(
      // Me-row highlight: one of the few spots allowed to spend the
      // saturated accent (as a pale tint) — see task-12 brief. Reads from
      // the theme (not a raw token) so it stays correct in dark mode too.
      tileColor: isMe ? theme.colorScheme.primaryContainer : null,
      leading: Text('${e.rank}', style: textTheme.labelLarge),
      title: Text(e.pseudo,
          style: isMe
              ? textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)
              : textTheme.bodyLarge),
      trailing: Text('${e.totalKm.toStringAsFixed(1)} km',
          style: textTheme.labelLarge),
    );
  }
}
