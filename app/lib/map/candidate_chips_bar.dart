/// The fullscreen loop/duration selection UI's bottom banner (task 8:
/// device-QA overhaul of task 6's candidates sheet). The owner's own words:
/// « pendant la sélection… cache les menus et mets les alternatives en petit
/// en bas pour mieux voir la carte » — so this replaces the old full-size
/// `CandidatesSheet` cards (task 6, since removed) with a single compact,
/// horizontally-scrollable row of vignettes (≤ ~96 px tall) plus a
/// normal-size « C'est parti » pill and a ✕ to leave selection (which
/// restores the top menus — see `map_screen.dart`'s
/// `shouldShowPlanningTopOverlay`).
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
/// `CandidatesSheet`'s convention (fix-round-1 finding it replaced): the
/// single outer `Positioned`/`Padding` in `map_screen.dart` already owns
/// `viewPadding.bottom` for every bottom banner, so this widget must never
/// add its own on top of that — enforced by wrapping in an explicit
/// [EdgeInsets.zero] `Padding` (keyed for the widget test) rather than just
/// leaving the root un-padded, so a future edit that reaches for padding
/// here trips the test instead of silently reintroducing the double-count
/// fix-round-1 fixed.
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
    this.kind,
  });

  final LoopPlanResult result;
  final int selectedIndex;
  final double speedKmh;
  final ValueChanged<int> onSelect;
  final VoidCallback onStart;
  final VoidCallback onOtherProposals;
  final VoidCallback onClose;

  /// The kind of plan [result] answers — fix-round-1 point 3: a single
  /// [PlanKind.toDestination] candidate is the direct route with no detour
  /// budget to work with (see `loopTargetFloorForDestination`'s doc
  /// comment); "Autres propositions" would be a deterministic no-op, so it
  /// is hidden rather than offered. `null` (defensive default) shows it, the
  /// same as every other kind/count combination.
  final PlanKind? kind;

  @override
  Widget build(BuildContext context) {
    final index = clampSelection(selectedIndex, result.candidates.length);
    final hideOtherProposals =
        kind != null &&
        shouldHideOtherProposals(
          candidateCount: result.candidates.length,
          kind: kind!,
        );
    return Padding(
      key: const Key('candidateChipsBarPadding'),
      padding: EdgeInsets.zero,
      child: Column(
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
              itemCount:
                  result.candidates.length + (hideOtherProposals ? 0 : 1),
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
      ),
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
                // Two lines rather than one 'X km · ~Y min' string: on a
                // 128 px chip that single line overflows into '4,7 km …' at
                // ordinary font scales (owner device QA, 2026-09-05), hiding
                // the duration entirely — the piece of information duration
                // mode was asked for. Distance and duration each get a line
                // that fits at any realistic scale instead.
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
                      child: Text(
                        '$km km',
                        style: theme.textTheme.labelLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: Text(
                    '~$minutes min',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(AppRadii.stadium),
                    ),
                    child: Text(
                      badge,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
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
    // Same width as the candidate chips: at 96 px « propositions » no longer
    // fit on one line and wrapped mid-word ('Autres pr/oposition/s' — owner
    // device QA, 2026-09-05). 128 px fits each word whole on its own line.
    width: 128,
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: const Text(
        'Autres\npropositions',
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12),
      ),
    ),
  );
}

/// The `SnackBar` shown when a plan request came back with no routable
/// candidate at all — brief's exact wording.
const kNoLoopCandidatesMessage =
    'Impossible de proposer une boucle ici — zone couverte ?';
