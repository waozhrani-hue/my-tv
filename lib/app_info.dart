/// Product naming, kept in one place so the window title, the About section
/// and the welcome screen cannot drift apart.
abstract final class AppInfo {
  /// What the outside world sees: launcher label, window title, file
  /// properties. Deliberately just the product name.
  static const name = 'My TV';

  /// Build edition. Shown inside the app only — on the welcome screen and in
  /// Settings → About — never in the launcher or the title bar.
  static const edition = 'إصدار خاص (لمعاليكم)';

  /// Keep in step with `version:` in pubspec.yaml.
  static const version = '1.6.0';
}
