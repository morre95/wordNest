/// The app's source of "now", injectable so scheduling and sync tests are
/// deterministic. Always UTC: rows are compared across devices whose local
/// time zones differ.
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now().toUtc();
