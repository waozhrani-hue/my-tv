import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/update_service.dart';

void main() {
  group('normalizeVersion', () {
    test('strips a leading v', () {
      expect(UpdateService.normalizeVersion('v1.2.0'), '1.2.0');
      expect(UpdateService.normalizeVersion('V2.0.1'), '2.0.1');
    });

    test('drops a build number', () {
      expect(UpdateService.normalizeVersion('1.2.0+7'), '1.2.0');
      expect(UpdateService.normalizeVersion('v1.2.0+7'), '1.2.0');
    });

    test('tolerates surrounding whitespace', () {
      expect(UpdateService.normalizeVersion('  v1.2.0  '), '1.2.0');
    });
  });

  group('isNewer', () {
    test('compares each component numerically, not as text', () {
      // The classic trap: "10" sorts before "9" as a string.
      expect(UpdateService.isNewer('1.10.0', '1.9.0'), isTrue);
      expect(UpdateService.isNewer('1.9.0', '1.10.0'), isFalse);
    });

    test('detects a newer major, minor or patch', () {
      expect(UpdateService.isNewer('2.0.0', '1.9.9'), isTrue);
      expect(UpdateService.isNewer('1.3.0', '1.2.9'), isTrue);
      expect(UpdateService.isNewer('1.2.1', '1.2.0'), isTrue);
    });

    test('the same version is not newer', () {
      expect(UpdateService.isNewer('1.2.0', '1.2.0'), isFalse);
      expect(UpdateService.isNewer('v1.2.0', '1.2.0+9'), isFalse);
    });

    test('an older version is not newer', () {
      expect(UpdateService.isNewer('1.1.9', '1.2.0'), isFalse);
    });

    test('missing components count as zero', () {
      expect(UpdateService.isNewer('1.2', '1.2.0'), isFalse);
      expect(UpdateService.isNewer('1.2.1', '1.2'), isTrue);
      expect(UpdateService.isNewer('2', '1.9.9'), isTrue);
    });

    test('a tag that is not a version does not trigger an update', () {
      expect(UpdateService.isNewer('latest', '1.2.0'), isFalse);
      expect(UpdateService.isNewer('', '1.2.0'), isFalse);
    });
  });

  group('parseRelease', () {
    Map<String, dynamic> payload(List<Map<String, dynamic>> assets) => {
      'tag_name': 'v1.3.0',
      'html_url': 'https://github.com/owner/repo/releases/tag/v1.3.0',
      'body': '  Fixes the thing.  ',
      'assets': assets,
    };

    test('picks the APK and the Windows installer out of the assets', () {
      final release = UpdateService.parseRelease(
        payload([
          {
            'name': 'app-release.apk',
            'browser_download_url': 'https://example/app-release.apk',
            'size': 97000000,
          },
          {
            'name': 'MyTV-Setup-1.3.0.exe',
            'browser_download_url': 'https://example/MyTV-Setup-1.3.0.exe',
            'size': 25000000,
          },
          {
            'name': 'notes.txt',
            'browser_download_url': 'https://example/notes.txt',
            'size': 120,
          },
        ]),
      );

      expect(release.version, '1.3.0');
      expect(release.tag, 'v1.3.0');
      expect(release.notes, 'Fixes the thing.');
      expect(release.apkUrl, 'https://example/app-release.apk');
      expect(release.apkBytes, 97000000);
      expect(release.windowsUrl, 'https://example/MyTV-Setup-1.3.0.exe');
      expect(release.windowsBytes, 25000000);
    });

    test('a release with no assets still parses', () {
      final release = UpdateService.parseRelease(payload([]));
      expect(release.version, '1.3.0');
      expect(release.apkUrl, isNull);
      expect(release.windowsUrl, isNull);
    });

    test('a missing assets list is treated as empty', () {
      final release = UpdateService.parseRelease({
        'tag_name': 'v1.0.0',
        'html_url': 'https://example/release',
      });
      expect(release.version, '1.0.0');
      expect(release.notes, '');
      expect(release.apkUrl, isNull);
    });

    test('asset matching ignores case', () {
      final release = UpdateService.parseRelease(
        payload([
          {
            'name': 'MyTV.APK',
            'browser_download_url': 'https://example/MyTV.APK',
            'size': 1,
          },
        ]),
      );
      expect(release.apkUrl, 'https://example/MyTV.APK');
    });
  });
}
