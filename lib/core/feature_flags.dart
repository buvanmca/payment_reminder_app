/// Compile-time feature flags.
///
/// These gate UI entry points without deleting the underlying implementation,
/// so a feature can be re-enabled by flipping a single constant.
library;

/// WhatsApp reminders are disabled app-wide. The dispatch code, API client,
/// and history channel remain intact (so previously-sent WhatsApp reminders
/// still render in Reports / Pending), but every UI entry point that would
/// *initiate* a WhatsApp send is hidden, and the scheduler never auto-sends
/// WhatsApp.
///
/// Sourced from the environment (like Flutter's own `kReleaseMode`) so it stays
/// a compile-time constant without the analyzer flagging the guarded branches
/// as dead code. Defaults to off; re-enable with:
///   flutter run --dart-define=WHATSAPP_ENABLED=true
const bool kWhatsAppEnabled =
    bool.fromEnvironment('WHATSAPP_ENABLED', defaultValue: false);
