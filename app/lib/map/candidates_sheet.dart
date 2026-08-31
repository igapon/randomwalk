/// The loop/duration planning candidates bottom sheet (task 6): up to 3
/// cards (real distance, personal-pace duration, an off-target badge, a
/// repeated-segment hint), a selection, and the « Autres propositions » /
/// « C'est parti » / ✕ actions. All display logic beyond simple string
/// interpolation lives in `plan_mode.dart` — this file is purely the widget.
library;

import 'package:flutter/material.dart';

import '../loop/loop_planner.dart';
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import 'plan_mode.dart';

/// Inset-safe: wraps its content in a [SafeArea] and adds the bottom system
/// inset itself, so callers (typically `showModalBottomSheet`) don't have to
/// special-case gesture vs. 3-button navigation — same rule `map_screen.dart`
/// follows for its own bottom banner.
class CandidatesSheet extends StatelessWidget {
  const CandidatesSheet({
    super.key,
    required this.result,
    required this.selectedIndex,
    required this.speedKmh,
    required this.onSelect,
    required this.onStart,
    required this.onOtherProposals,
    required this.onClose,
  });

  final LoopPlanResult result;
  final int selectedIndex;
  final double speedKmh;
  final ValueChanged<int> onSelect;
  final VoidCallback onStart;
  final VoidCallback onOtherProposals;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final index = clampSelection(selectedIndex, result.candidates.length);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Propositions',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Fermer',
                  onPressed: onClose,
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < result.candidates.length; i++) ...[
              _CandidateCard(
                candidate: result.candidates[i],
                speedKmh: speedKmh,
                selected: i == index,
                onTap: () => onSelect(i),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onOtherProposals,
                    child: const Text('Autres propositions'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: result.candidates.isEmpty ? null : onStart,
                    icon: const WaymarkDiamond(size: 12, color: AppColors.ink),
                    label: const Text("C'est parti"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.candidate,
    required this.speedKmh,
    required this.selected,
    required this.onTap,
  });

  final LoopCandidate candidate;
  final double speedKmh;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final distanceKm = candidate.route.distanceKm;
    final duration = estimatedDuration(distanceKm, speedKmh);
    final badge = gapBadgeLabel(candidate);
    final hint = repeatedRatioHint(candidate.repeatedRatio);
    final km = distanceKm.toStringAsFixed(1).replaceAll('.', ',');
    final minutes = duration.inMinutes;

    return Card(
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$km km · ~$minutes min',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(hint, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(AppRadii.stadium),
                  ),
                  child: Text(badge,
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer)),
                ),
              ],
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The `SnackBar` shown when a plan request came back with no routable
/// candidate at all — brief's exact wording.
const kNoLoopCandidatesMessage =
    'Impossible de proposer une boucle ici — zone couverte ?';
