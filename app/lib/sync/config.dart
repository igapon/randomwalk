/// Compile-time Supabase configuration, read from `--dart-define`.
///
/// There is deliberately no other source for this (no asset file, no
/// runtime settings screen to type it into): a build either has these two
/// values baked in at compile time or it doesn't, which is what lets
/// [fromEnvironment] be a `const`-evaluated check and lets the M5 global
/// constraint ("sans configuration, rien ne change") hold for every build
/// that doesn't pass them — see `docs/superpowers/plans/2026-09-01-m5-sync.
/// md` and `supabase/README.md` (Task 2) for the owner-facing setup guide
/// and the exact build command.
///
/// [anonKey] is Supabase's "anon" public API key, not a secret: it is
/// meant to be embedded in client builds (and is trivially recoverable from
/// any of them, e.g. via `strings` on the APK) — data protection comes from
/// Postgres Row Level Security policies on the server (Task 2's
/// `supabase/migrations/0001_init.sql`), not from keeping this key hidden.
/// Nothing about this class needs to be treated as a secret; what must
/// never land in the repo is the project's *service role* key, which this
/// app never uses.
class SupabaseConfig {
  final String url;
  final String anonKey;

  const SupabaseConfig({required this.url, required this.anonKey});

  /// Reads `SUPABASE_URL`/`SUPABASE_ANON_KEY` from `--dart-define`. Returns
  /// `null` when either is absent or empty — which is the default for
  /// every build (`flutter run`/`flutter test`/`flutter build` with no
  /// `--dart-define` flags), so [SyncBackend]'s default provider falls back
  /// to [UnconfiguredBackend] and the app behaves exactly like M4.
  static SupabaseConfig? fromEnvironment() {
    const url = String.fromEnvironment('SUPABASE_URL');
    const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    if (url.isEmpty || anonKey.isEmpty) return null;
    return SupabaseConfig(url: url, anonKey: anonKey);
  }
}
