import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/cloud_verification_models.dart';

void main() {
  group('CloudAppConfigResponse', () {
    test('parses successful config payload', () {
      final response = CloudAppConfigResponse.fromJson({
        'code': 200,
        'msg': {
          'version': '1.2.3',
          'version_info': 'Fixes',
          'app_update_show': 'y',
          'app_update_url': 'https://example.com',
          'app_update_must': 'n',
        },
        'time': 1,
        'check': 'abc',
      });

      expect(response.isSuccess, isTrue);
      expect(response.msg?.version, '1.2.3');
      expect(response.msg?.formattedVersionInfo, ['Fixes']);
    });

    test('ignores non-object failure msg payload', () {
      final response = CloudAppConfigResponse.fromJson({
        'code': 100,
        'msg': '请绑定应用ID',
        'time': 1,
        'check': 'abc',
      });

      expect(response.isSuccess, isFalse);
      expect(response.msg, isNull);
    });
  });

}
