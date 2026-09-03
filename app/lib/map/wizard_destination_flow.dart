/// Task 2i wizard step 2, « Destination » branch: a fullscreen address
/// search (keyboard open immediately), then an optional distance/durée
/// constraint. Two screens — "une étape = un geste principal" — pushed onto
/// the ambient Navigator, popped back to the wizard's step 1 the same
/// "natural" way any pushed screen in this app already does. No map
/// anywhere in this file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';
import '../trip/trip_controller.dart';
import '../valhalla/models.dart';
import 'geocoding.dart';
import 'latest_only.dart';
import 'plan_mode.dart';
import 'route_controller.dart' show geocodingServiceProvider;
import 'wizard_actions.dart';
import 'wizard_defaults_store.dart';

class WizardDestinationSearchScreen extends ConsumerStatefulWidget {
  const WizardDestinationSearchScreen({super.key, required this.onEnterMap});

  final EnterMapCallback onEnterMap;

  @override
  ConsumerState<WizardDestinationSearchScreen> createState() =>
      _WizardDestinationSearchScreenState();
}

class _WizardDestinationSearchScreenState
    extends ConsumerState<WizardDestinationSearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _generation = LatestOnly();
  Timer? _debounce;
  List<GeocodeResult> _results = [];
  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // "clavier ouvert direct" — brief point 2: the keyboard is up the
    // instant this screen is on screen, no extra tap to focus the field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      _generation.start();
      setState(() {
        _results = [];
        _error = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _runSearch(query),
    );
  }

  Future<void> _runSearch(String query) async {
    final gen = _generation.start();
    if (!mounted) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await ref.read(geocodingServiceProvider).search(query);
      if (!mounted || !_generation.isCurrent(gen)) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } on GeocodingException catch (e) {
      if (!mounted || !_generation.isCurrent(gen)) return;
      setState(() {
        _results = [];
        _searching = false;
        _error = searchErrorMessage(e.kind);
      });
    }
  }

  Future<void> _selectResult(GeocodeResult result) async {
    _focusNode.unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WizardConstraintScreen(
          destination: (result.lat, result.lon),
          destinationLabel: result.label,
          onEnterMap: widget.onEnterMap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showResults = _searching || _error != null || _results.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Rechercher une adresse…',
            border: InputBorder.none,
          ),
        ),
      ),
      body: SafeArea(
        child: !showResults
            ? const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Text('Tapez une adresse, une ville, un lieu…'),
              )
            : _searching
            ? const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(_error!),
              )
            : ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, i) => ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(_results[i].label),
                  onTap: () => _selectResult(_results[i]),
                ),
              ),
      ),
    );
  }
}

/// Quick-pick presets — same values `WizardPromenadeScreen` offers, kept in
/// sync manually rather than shared: this screen's presets describe "how
/// much further than the direct route", `WizardPromenadeScreen`'s describe
/// "how big a loop", different enough questions that a future divergence
/// (e.g. smaller Destination presets) should not be blocked by a shared
/// constant.
const _kLoopPresetsKm = [3.0, 5.0, 8.0, 12.0, 20.0];
const _kDurationPresetsMin = [20, 30, 45, 60, 90];

/// "puis contrainte optionnelle distance OU durée" — brief point 2. Three
/// choices, one main gesture each: no constraint (straight to `MapScreen`'s
/// existing `_planRoute`), a distance detour budget, or a duration one.
class WizardConstraintScreen extends ConsumerStatefulWidget {
  const WizardConstraintScreen({
    super.key,
    required this.destination,
    required this.destinationLabel,
    required this.onEnterMap,
  });

  final (double, double) destination;
  final String destinationLabel;
  final EnterMapCallback onEnterMap;

  @override
  ConsumerState<WizardConstraintScreen> createState() =>
      _WizardConstraintScreenState();
}

/// `null` reads as "aucune contrainte" — a direct itinerary.
enum _Constraint { none, distance, duration }

class _WizardConstraintScreenState
    extends ConsumerState<WizardConstraintScreen> {
  _Constraint _constraint = _Constraint.none;
  double _loopTargetKm = defaultLoopTargetKm(RoutingProfile.walk);
  Duration _durationTarget = kDurationTargetDefault;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefaults());
  }

  Future<void> _loadDefaults() async {
    // The Destination branch has no profile picker of its own (brief point
    // 2 only asks for one under « Promenade ») — the current
    // `TripController` profile is the best-known default for the loop
    // target's own profile-based fallback (`defaultLoopTargetKm`).
    final profile = ref.read(tripControllerProvider).profile;
    final defaults = await WizardDefaultsStore().load(profile);
    if (!mounted) return;
    setState(() {
      _loopTargetKm = defaults.loopTargetKm;
      _durationTarget = defaults.durationTarget;
    });
  }

  Future<void> _continue() async {
    if (_committing) return;
    setState(() => _committing = true);
    final handoff = await commitDestinationPlan(
      ref.read(tripControllerProvider),
      destination: widget.destination,
      constraintMode: switch (_constraint) {
        _Constraint.none => null,
        _Constraint.distance => PlanMode.loop,
        _Constraint.duration => PlanMode.duration,
      },
      loopTargetKm: _constraint == _Constraint.distance ? _loopTargetKm : null,
      durationTarget: _constraint == _Constraint.duration
          ? _durationTarget
          : null,
    );
    if (!mounted) return;
    widget.onEnterMap(handoff);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Contrainte (optionnel)')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.destinationLabel,
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  ChoiceChip(
                    label: const Text('Aucune contrainte'),
                    selected: _constraint == _Constraint.none,
                    onSelected: (_) =>
                        setState(() => _constraint = _Constraint.none),
                  ),
                  ChoiceChip(
                    label: const Text('Distance'),
                    selected: _constraint == _Constraint.distance,
                    onSelected: (_) =>
                        setState(() => _constraint = _Constraint.distance),
                  ),
                  ChoiceChip(
                    label: const Text('Durée'),
                    selected: _constraint == _Constraint.duration,
                    onSelected: (_) =>
                        setState(() => _constraint = _Constraint.duration),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_constraint == _Constraint.distance)
                _DestDistancePicker(
                  km: _loopTargetKm,
                  onChanged: (km) => setState(() => _loopTargetKm = km),
                )
              else if (_constraint == _Constraint.duration)
                _DestDurationPicker(
                  duration: _durationTarget,
                  onChanged: (d) => setState(() => _durationTarget = d),
                ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed: _committing ? null : _continue,
                child: _committing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _constraint == _Constraint.none
                            ? "Planifier l'itinéraire"
                            : 'Proposer',
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DestDistancePicker extends StatelessWidget {
  const _DestDistancePicker({required this.km, required this.onChanged});
  final double km;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = '${km.toStringAsFixed(1).replaceAll('.', ',')} km';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            for (final preset in _kLoopPresetsKm)
              ChoiceChip(
                label: Text('${preset.toStringAsFixed(0)} km'),
                selected: (km - preset).abs() < 0.05,
                onSelected: (_) => onChanged(clampLoopTargetKm(preset)),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Slider(
          value: km,
          min: kLoopTargetMinKm,
          max: kLoopTargetMaxKm,
          divisions: ((kLoopTargetMaxKm - kLoopTargetMinKm) / kLoopTargetStepKm)
              .round(),
          label: label,
          onChanged: (v) => onChanged(clampLoopTargetKm(v)),
        ),
        Align(alignment: Alignment.centerRight, child: Text(label)),
      ],
    );
  }
}

class _DestDurationPicker extends StatelessWidget {
  const _DestDurationPicker({required this.duration, required this.onChanged});
  final Duration duration;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final label = hours > 0
        ? (minutes == 0 ? '$hours h' : '$hours h $minutes')
        : '$minutes min';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            for (final preset in _kDurationPresetsMin)
              ChoiceChip(
                label: Text(preset >= 60 ? '${preset ~/ 60} h' : '$preset min'),
                selected: duration.inMinutes == preset,
                onSelected: (_) =>
                    onChanged(clampDurationTarget(Duration(minutes: preset))),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Slider(
          value: duration.inMinutes.toDouble(),
          min: kDurationTargetMin.inMinutes.toDouble(),
          max: kDurationTargetMax.inMinutes.toDouble(),
          divisions:
              (kDurationTargetMax.inMinutes - kDurationTargetMin.inMinutes) ~/
              kDurationTargetStep.inMinutes,
          label: label,
          onChanged: (v) =>
              onChanged(clampDurationTarget(Duration(minutes: v.round()))),
        ),
        Align(alignment: Alignment.centerRight, child: Text(label)),
      ],
    );
  }
}
