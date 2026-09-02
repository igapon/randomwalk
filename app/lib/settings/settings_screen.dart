import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../history/trip_history_screen.dart';
import '../nav/tts.dart';
import '../session/recorder.dart';
import '../tracking/device_channel.dart';
import '../tracking/permissions.dart';
import '../trip/trip_controller.dart';
import 'account_tile.dart';
import 'alert_settings.dart';
import 'battery_optimization.dart';
import 'data_export.dart';
import 'identity.dart';
import 'local_purge.dart';
import 'theme_mode_tile.dart';

/// Player settings: editable pseudo, plus read-only identity and local
/// stats. Reached via the settings icon in the app's top bar.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _totalStore = TotalDistanceStore();
  final _formKey = GlobalKey<FormState>();
  final _pseudoController = TextEditingController();

  late Future<
    ({
      PlayerIdentity identity,
      double totalKm,
      bool ttsEnabled,
      bool hapticsEnabled,
    })
  >
  _future;

  /// Probed once, independently of [_future] — a toggle change (haptics
  /// included) reloads [_future] via [_load], and re-asking the native side
  /// whether French TTS is available every time either switch moves would
  /// be pointless platform-channel chatter for a fact that never changes
  /// mid-session.
  late Future<bool> _ttsAvailable;

  /// The probe's own [NativeTtsSpeaker] instance — kept only long enough to
  /// [NativeTtsSpeaker.shutdown] it once [_ttsAvailable] has answered (see
  /// [_probeTts]). This is purely an availability check, not guidance being
  /// spoken, so there is no reason for the native `TextToSpeech` engine
  /// `init()` built to stay allocated for the rest of the screen's lifetime
  /// (task-7 item 3).
  final _ttsProbe = NativeTtsSpeaker();

  /// Probed once, same reasoning as [_ttsAvailable]: the device manufacturer
  /// cannot change mid-session, so this is asked once rather than on every
  /// [_load] — see `isAggressiveBatteryOem`.
  late Future<String?> _manufacturer;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _ttsAvailable = _probeTts();
    _manufacturer = const DeviceChannel().manufacturer();
  }

  /// Asks the native side whether French TTS is usable, then immediately
  /// releases the engine that answer required — see [_ttsProbe]'s doc
  /// comment. `shutdown()` runs regardless of the answer (including a
  /// probe that came back unavailable) so a real engine never leaks either
  /// way.
  Future<bool> _probeTts() async {
    final available = await _ttsProbe.init();
    await _ttsProbe.shutdown();
    return available;
  }

  Future<
    ({
      PlayerIdentity identity,
      double totalKm,
      bool ttsEnabled,
      bool hapticsEnabled,
    })
  >
  _load() async {
    final identity = await ref.read(identityStoreProvider).get();
    final totalKm = await _totalStore.totalKm();
    final alertSettings = ref.read(alertSettingsStoreProvider);
    final ttsEnabled = await alertSettings.ttsEnabled();
    final hapticsEnabled = await alertSettings.hapticsEnabled();
    _pseudoController.text = identity.pseudo;
    return (
      identity: identity,
      totalKm: totalKm,
      ttsEnabled: ttsEnabled,
      hapticsEnabled: hapticsEnabled,
    );
  }

  Future<void> _setTtsEnabled(bool value) async {
    await ref.read(tripControllerProvider).setTtsEnabled(value);
    setState(() => _future = _load());
  }

  Future<void> _setHapticsEnabled(bool value) async {
    await ref.read(tripControllerProvider).setHapticsEnabled(value);
    setState(() => _future = _load());
  }

  @override
  void dispose() {
    _pseudoController.dispose();
    super.dispose();
  }

  String? _validatePseudo(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return 'Le pseudo est requis.';
    if (trimmed.length > 24) return 'Maximum 24 caractères.';
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref
        .read(identityStoreProvider)
        .setPseudo(_pseudoController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Pseudo enregistré.')));
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body:
          FutureBuilder<
            ({
              PlayerIdentity identity,
              double totalKm,
              bool ttsEnabled,
              bool hapticsEnabled,
            })
          >(
            future: _future,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final identity = snapshot.data!.identity;
              final totalKm = snapshot.data!.totalKm;
              final ttsEnabled = snapshot.data!.ttsEnabled;
              final hapticsEnabled = snapshot.data!.hapticsEnabled;
              return SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFormField(
                          controller: _pseudoController,
                          decoration: const InputDecoration(
                            labelText: 'Pseudo',
                          ),
                          maxLength: 24,
                          validator: _validatePseudo,
                          onFieldSubmitted: (_) => _save(),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ElevatedButton(
                            onPressed: _save,
                            child: const Text('Enregistrer'),
                          ),
                        ),
                        const Divider(height: 32),
                        Text(
                          'Identifiant : ${identity.userId}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Distance totale : ${totalKm.toStringAsFixed(1)} km',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const Divider(height: 32),
                        FutureBuilder<bool>(
                          future: _ttsAvailable,
                          builder: (context, ttsSnapshot) {
                            // Defaults to unavailable while the native probe is
                            // still in flight — briefly disabled rather than
                            // briefly claiming a capability the device may not
                            // have.
                            final available = ttsSnapshot.data ?? false;
                            return SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Guidage vocal'),
                              subtitle: Text(
                                available
                                    ? 'Instructions de navigation lues à voix haute'
                                    : 'Synthèse vocale indisponible sur cet appareil',
                              ),
                              value: available && ttsEnabled,
                              onChanged: available ? _setTtsEnabled : null,
                            );
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Vibrations et alertes'),
                          subtitle: const Text(
                            "Vibration et son à l'approche d'une manœuvre",
                          ),
                          value: hapticsEnabled,
                          onChanged: _setHapticsEnabled,
                        ),
                        const ThemeModeTile(),
                        FutureBuilder<String?>(
                          future: _manufacturer,
                          builder: (context, manufacturerSnapshot) {
                            if (!isAggressiveBatteryOem(
                              manufacturerSnapshot.data,
                            )) {
                              return const SizedBox.shrink();
                            }
                            return const _BatteryReliabilityTile();
                          },
                        ),
                        const Divider(height: 32),
                        const TripHistorySettingsTile(),
                        const AboutDataTile(),
                        const ExportDataTile(),
                        const AccountTile(),
                        const PurgeRetryTile(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }
}

/// Shown only on OEMs known to kill background location aggressively beyond
/// stock Android (see `isAggressiveBatteryOem`) — task-8 brief point 9.
/// `ACTION_APPLICATION_DETAILS_SETTINGS` (via `permission_handler`'s
/// `openAppSettings`, already used by the main-screen banners for the same
/// purpose) is used deliberately instead of the
/// `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` intent: the latter needs
/// the `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission, which Play's
/// policy restricts to apps whose *core* function requires it — a walking
/// tracker's occasional background fix does not clearly qualify, and
/// mis-declaring it risks a listing rejection. The app details page lets
/// the user reach the OEM's own battery/autostart controls in two taps
/// instead of one, at zero policy risk.
class _BatteryReliabilityTile extends StatelessWidget {
  const _BatteryReliabilityTile();

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.battery_alert_outlined),
    title: const Text('Suivi fiable en arrière-plan'),
    subtitle: const Text(
      "Ce téléphone peut interrompre le suivi en arrière-plan. "
      "Ouvrez les réglages de l'app et autorisez-la à fonctionner "
      "sans restriction de batterie (démarrage automatique / sans "
      'contrainte).',
    ),
    onTap: () => PluginPermissionService().openSettings(),
  );
}

/// Settings tile disclosing the map/routing data sources — required
/// alongside the map's own small on-screen credit (see `_MapAttribution` in
/// `map_screen.dart`) by OpenStreetMap's and OpenFreeMap's usage terms, and
/// a natural place to also credit the routing engine.
class AboutDataTile extends StatelessWidget {
  const AboutDataTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.info_outline),
    title: const Text('À propos des données'),
    subtitle: const Text('Sources des cartes et du calcul d\'itinéraire'),
    onTap: () => showDialog<void>(
      context: context,
      builder: (context) => const _AboutDataDialog(),
    ),
  );
}

class _AboutDataDialog extends StatelessWidget {
  const _AboutDataDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('À propos des données'),
    content: const Text(
      '• Cartes : © les contributeurs d\'OpenStreetMap, sous licence '
      'ODbL.\n'
      '• Tuiles cartographiques : OpenFreeMap (openfreemap.org), à '
      'partir des mêmes données OpenStreetMap.\n'
      '• Calcul d\'itinéraire : moteur de routage Valhalla, hors ligne '
      'à partir de données OpenStreetMap traitées par ce projet.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Fermer'),
      ),
    ],
  );
}
