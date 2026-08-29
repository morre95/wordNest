import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reports speech-recognition models that are installed and ready to use.
///
/// A null result means the platform cannot distinguish installed models from
/// merely supported locales. An empty result means it can, and none are ready.
abstract interface class OnDeviceSpeechModels {
  Future<List<String>?> installedLocaleIds();
}

/// Android obtains this metadata from `RecognitionSupport` in MainActivity.
/// Other platforms keep using the locale information supplied by
/// `speech_to_text` until they have an equally precise native query.
class PlatformOnDeviceSpeechModels implements OnDeviceSpeechModels {
  const PlatformOnDeviceSpeechModels();

  static const _channel = MethodChannel('com.wordnest.app/speech_models');
  static const _queryTimeout = Duration(seconds: 2);

  @override
  Future<List<String>?> installedLocaleIds() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;

    try {
      return await _channel
              .invokeListMethod<String>('installedOnDeviceLanguages')
              .timeout(_queryTimeout) ??
          const [];
    } on MissingPluginException {
      // Be conservative if the Android host and Dart code are ever briefly out
      // of step: do not claim that an offline model exists when it is unknown.
      return const [];
    } on PlatformException {
      return const [];
    } on TimeoutException {
      return const [];
    }
  }
}
