import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../session/recorder.dart';
import '../settings/identity.dart';
import 'repository.dart';

const _kOfflineMessage = 'Classement indisponible hors ligne';

/// Displays the top-50 leaderboard and the player's own rank. Best-effort
/// submits the local total km on open (and on pull-to-refresh) so the
/// backend stays in sync even if the last session's submit failed; the
/// local [TotalDistanceStore] total always remains the source of truth.
class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  final _identityStore = IdentityStore();
  final _totalStore = TotalDistanceStore();
  late Future<LeaderboardData> _future;

  @override
  void initState() {
    super.initState();
    _future = _submitAndFetch();
  }

  Future<LeaderboardData> _submitAndFetch() async {
    final identity = await _identityStore.get();
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

  Future<void> _refresh() async {
    final next = _submitAndFetch();
    setState(() => _future = next);
    await next.catchError((_) => const LeaderboardData(top: [], me: null));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<LeaderboardData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _buildError();
          }
          return _buildList(snapshot.data!);
        },
      ),
    );
  }

  Widget _buildError() {
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
                    const Text(_kOfflineMessage, textAlign: TextAlign.center),
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
    return ListTile(
      tileColor: isMe ? Theme.of(context).colorScheme.primaryContainer : null,
      title: Text(
        '${e.rank}. ${e.pseudo} — ${e.totalKm.toStringAsFixed(1)} km',
        style: isMe ? const TextStyle(fontWeight: FontWeight.bold) : null,
      ),
    );
  }
}
