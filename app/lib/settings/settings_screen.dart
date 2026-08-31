import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../session/recorder.dart';
import '../trip/trip_controller.dart';
import 'alert_settings.dart';
import 'identity.dart';

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
      ({PlayerIdentity identity, double totalKm, bool ttsEnabled, bool hapticsEnabled})> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<({PlayerIdentity identity, double totalKm, bool ttsEnabled, bool hapticsEnabled})>
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
    await ref.read(identityStoreProvider).setPseudo(_pseudoController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Pseudo enregistré.')));
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: FutureBuilder<
          ({PlayerIdentity identity, double totalKm, bool ttsEnabled, bool hapticsEnabled})>(
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
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _pseudoController,
                      decoration: const InputDecoration(labelText: 'Pseudo'),
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
                    Text('Identifiant : ${identity.userId}',
                        style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 8),
                    Text('Distance totale : ${totalKm.toStringAsFixed(1)} km',
                        style: Theme.of(context).textTheme.bodyMedium),
                    const Divider(height: 32),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Guidage vocal'),
                      // No French TTS ships yet — see NoopTtsSpeaker's doc
                      // comment (nav/tts.dart) for the upstream blocker —
                      // but the setting itself is real and forward-facing,
                      // so it should not claim an effect it does not have.
                      subtitle: const Text(
                          'Instructions lues à voix haute (bientôt disponible)'),
                      value: ttsEnabled,
                      onChanged: _setTtsEnabled,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Vibrations et alertes'),
                      subtitle: const Text(
                          "Vibration et son à l'approche d'une manœuvre"),
                      value: hapticsEnabled,
                      onChanged: _setHapticsEnabled,
                    ),
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
