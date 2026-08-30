import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// The player's stable identity: a device-generated uuid and a display
/// pseudo, both persisted locally and used to identify the player on the
/// leaderboard backend.
class PlayerIdentity {
  final String userId;
  final String pseudo;
  const PlayerIdentity({required this.userId, required this.pseudo});
}

/// Persists and retrieves the player's identity, generating a uuid v4 and a
/// default pseudo (`Marcheur-XXXX`) on first access.
class IdentityStore {
  static const _idKey = 'player_id', _pseudoKey = 'player_pseudo';

  Future<PlayerIdentity> get() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_idKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_idKey, id);
    }
    var pseudo = prefs.getString(_pseudoKey);
    if (pseudo == null) {
      pseudo = 'Marcheur-${id.substring(0, 4).toUpperCase()}';
      await prefs.setString(_pseudoKey, pseudo);
    }
    return PlayerIdentity(userId: id, pseudo: pseudo);
  }

  /// Updates the pseudo. Throws [ArgumentError] if outside the 1-24 char
  /// range once trimmed; callers should validate user input beforehand.
  Future<void> setPseudo(String pseudo) async {
    final trimmed = pseudo.trim();
    if (trimmed.isEmpty || trimmed.length > 24) {
      throw ArgumentError('pseudo must be 1-24 chars');
    }
    await (await SharedPreferences.getInstance())
        .setString(_pseudoKey, trimmed);
  }
}

final identityStoreProvider = Provider<IdentityStore>((ref) => IdentityStore());
