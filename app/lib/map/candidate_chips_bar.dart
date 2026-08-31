/// The fullscreen loop/duration selection UI's bottom banner (task 8:
/// device-QA overhaul of task 6's candidates sheet). The owner's own words:
/// « pendant la sélection… cache les menus et mets les alternatives en petit
/// en bas pour mieux voir la carte » — so this replaces the old full-size
/// [CandidatesSheet] cards with a single compact, horizontally-scrollable row
/// of vignettes (≤ ~96 px tall) plus a normal-size « C'est parti » pill and a
/// ✕ to leave selection (which restores the top menus — see
/// `map_screen.dart`'s `shouldShowPlanningTopOverlay`).
///
/// All display logic beyond simple string interpolation still lives in
/// `plan_mode.dart` — this file is purely the widget, same split the old
/// sheet used.
library;

import 'package:flutter/material.dart';

import '../loop/loop_planner.dart';
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import 'plan_mode.dart';

/// The compact row's height budget — task-8 brief point 1: "hauteur ≤ ~96
/// px". Kept a few px under that ceiling for the row's own vertical margins.
const double kCandidateChipRowHeight = 88.0;

/// Self-pads *nothing* for the bottom system inset, matching the old
/// [CandidatesSheet]'s convention (fix-round-1 finding it replaced): the
/// single outer `Positioned`/`Padding` in `map_screen.dart` already owns
/// `viewPadding.bottom` for every bottom banner, so this widget must never
/// add its own on top of that.
class CandidateChipsBar extends StatelessWidget {
  const CandidateChipsBar({
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
    final index = clampSelection(selectedIndex, result.candidates.length);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: result.candidates.isEmpty ? null : onStart,
                icon: const WaymarkDiamond(size: 12, color: AppColors.ink),
                label: const Text("C'est parti"),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Fermer',
              onPressed: onClose,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          key: const Key('candidateChipsRow'),
          height: kCandidateChipRowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: result.candidates.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              if (i == result.candidates.length) {
                return _OtherProposalsChip(onTap: onOtherProposals);
              }
              return _CandidateChip(
                candidate: result.candidates[i],
                speedKmh: speedKmh,
                selected: i == index,
                onTap: () => onSelect(i),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CandidateChip extends StatelessWidget {
  const _CandidateChip({
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
    final km = distanceKm.toStringAsFixed(1).replaceAll('.', ',');
    final minutes = (duration.inSeconds / 60).round();

    return SizedBox(
      width: 128,
      child: Card(
        margin: EdgeInsets.zero,
        color: selected ? theme.colorScheme.primaryContainer : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.card),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 16,
                      color: selected ? theme.colorScheme.primary : null,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text('$km km · ~$minutes min',
                          style: theme.textTheme.labelLarge,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
                if (badge != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(AppRadii.stadium),
                    ),
                    child: Text(badge,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// « Autres propositions » — a small action inside the same scrollable row
/// (task-8 brief point 1), not a full-width button below it any more.
class _OtherProposalsChip extends StatelessWidget {
  const _OtherProposalsChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 96,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: const Text(
            'Autres propositions',
            textAlign: TextAlign.center,
            maxLines: 3,
            style: TextStyle(fontSize: 11),
          ),
        ),
      );
}

/// The `SnackBar` shown when a plan request came back with no routable
/// candidate at all — brief's exact wording.
const kNoLoopCandidatesMessage =
    'Impossible de proposer une boucle ici — zone couverte ?';
