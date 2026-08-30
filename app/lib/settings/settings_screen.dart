import 'package:flutter/material.dart';
import '../session/recorder.dart';
import 'identity.dart';

/// Player settings: editable pseudo, plus read-only identity and local
/// stats. Reached via the settings icon in the app's top bar.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _identityStore = IdentityStore();
  final _totalStore = TotalDistanceStore();
  final _formKey = GlobalKey<FormState>();
  final _pseudoController = TextEditingController();

  late Future<({PlayerIdentity identity, double totalKm})> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<({PlayerIdentity identity, double totalKm})> _load() async {
    final identity = await _identityStore.get();
    final totalKm = await _totalStore.totalKm();
    _pseudoController.text = identity.pseudo;
    return (identity: identity, totalKm: totalKm);
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
    await _identityStore.setPseudo(_pseudoController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Pseudo enregistré.')));
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: FutureBuilder<({PlayerIdentity identity, double totalKm})>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final identity = snapshot.data!.identity;
          final totalKm = snapshot.data!.totalKm;
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
