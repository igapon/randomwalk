/// Task 2i wizard step 2, « Promenade » branch: distance OU durée (chips +
/// saisie) et profil marche/vélo — one screen, one main gesture (« Proposer
/// »). No map anywhere in this file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';
import '../trip/trip_controller.dart';
import '../valhalla/models.dart';
import 'plan_mode.dart';
import 'wizard_actions.dart';
import 'wizard_defaults_store.dart';

/// Quick-pick presets for the Distance chips — a brisk city walk through a
/// full afternoon's ride, snapped through [clampLoopTargetKm] the same way
/// the slider itself is.
const _kLoopPresetsKm = [3.0, 5.0, 8.0, 12.0, 20.0];

/// Quick-pick presets for the Durée chips, in minutes.
const _kDurationPresetsMin = [20, 30, 45, 60, 90];

class WizardPromenadeScreen extends ConsumerStatefulWidget {
  const WizardPromenadeScreen({super.key, required this.onEnterMap});

  final EnterMapCallback onEnterMap;

  @override
  ConsumerState<WizardPromenadeScreen> createState() =>
      _WizardPromenadeScreenState();
}

class _WizardPromenadeScreenState extends ConsumerState<WizardPromenadeScreen> {
  PlanMode _mode = PlanMode.loop;
  double _loopTargetKm = defaultLoopTargetKm(RoutingProfile.walk);
  Duration _durationTarget = kDurationTargetDefault;
  RoutingProfile _profile = RoutingProfile.walk;
  bool _loaded = false;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _profile = ref.read(tripControllerProvider).profile;
    unawaited(_loadDefaults());
  }

  Future<void> _loadDefaults() async {
    final defaults = await WizardDefaultsStore().load(_profile);
    if (!mounted) return;
    setState(() {
      _mode = defaults.mode;
      _loopTargetKm = defaults.loopTargetKm;
      _durationTarget = defaults.durationTarget;
      _loaded = true;
    });
  }

  Future<void> _propose() async {
    if (_committing) return;
    setState(() => _committing = true);
    final handoff = await commitPromenadePlan(
      ref.read(tripControllerProvider),
      mode: _mode,
      loopTargetKm: _loopTargetKm,
      durationTarget: _durationTarget,
      profile: _profile,
    );
    if (!mounted) return;
    widget.onEnterMap(handoff);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Promenade')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Contrainte', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              SegmentedButton<PlanMode>(
                segments: const [
                  ButtonSegment(value: PlanMode.loop, label: Text('Distance')),
                  ButtonSegment(value: PlanMode.duration, label: Text('Durée')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_mode == PlanMode.loop)
                _DistancePicker(
                  km: _loopTargetKm,
                  onChanged: (km) => setState(() => _loopTargetKm = km),
                )
              else
                _DurationPicker(
                  duration: _durationTarget,
                  onChanged: (d) => setState(() => _durationTarget = d),
                ),
              const SizedBox(height: AppSpacing.lg),
              Text('Profil', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              SegmentedButton<RoutingProfile>(
                segments: const [
                  ButtonSegment(
                    value: RoutingProfile.walk,
                    label: Text('Marche'),
                    icon: Icon(Icons.directions_walk),
                  ),
                  ButtonSegment(
                    value: RoutingProfile.bike,
                    label: Text('Vélo'),
                    icon: Icon(Icons.directions_bike),
                  ),
                ],
                selected: {_profile},
                onSelectionChanged: (s) => setState(() => _profile = s.first),
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed: (_loaded && !_committing) ? _propose : null,
                child: _committing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Proposer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DistancePicker extends StatelessWidget {
  const _DistancePicker({required this.km, required this.onChanged});
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

class _DurationPicker extends StatelessWidget {
  const _DurationPicker({required this.duration, required this.onChanged});
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
