import '../tracking/permissions.dart';

/// French copy shared by the two screens that can start a trip, so the map
/// and the session tab cannot drift apart on what a refusal reads like —
/// and so the session screen does not have to import the map screen for a
/// string.
const kLocationDeniedMessage =
    'Localisation refusée — activez-la dans les réglages.';
const kPositionUnavailableMessage =
    'Position indisponible — activez la localisation ou définissez un départ manuel.';
const kLocationServiceOffMessage =
    'Localisation désactivée — activez-la dans les réglages Android.';
const kOpenedSettingsMessage =
    'Choisissez « Autoriser tout le temps », puis appuyez de nouveau sur Démarrer.';

/// Why a trip refused to start, phrased for the user from the reason the
/// permission flow gave.
String startFailureMessage(TripPermissionOutcome? outcome) =>
    switch (outcome) {
      TripPermissionOutcome.locationServiceOff => kLocationServiceOffMessage,
      TripPermissionOutcome.openedSettings => kOpenedSettingsMessage,
      _ => kPositionUnavailableMessage,
    };
