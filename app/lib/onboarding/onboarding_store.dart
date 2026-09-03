import 'package:shared_preferences/shared_preferences.dart';

/// Task 2b brief item 2a: the flag name is pinned by the brief itself.
const kOnboardedPrefKey = 'onboarded_v1';

/// Whether the first-launch onboarding screen has already been shown and its
/// permission flow run to completion. False on a fresh install, and false
/// again if the process is killed mid-onboarding — see [OnboardingGate]'s
/// own doc comment on why the flag is only set *after* the flow, not at
/// build time.
Future<bool> isOnboarded() async =>
    (await SharedPreferences.getInstance()).getBool(kOnboardedPrefKey) ?? false;

Future<void> markOnboarded() async =>
    (await SharedPreferences.getInstance()).setBool(kOnboardedPrefKey, true);
