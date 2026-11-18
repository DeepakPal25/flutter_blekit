import 'dart:async';

/// Lets queued microtasks and zero-length timers run.
Future<void> settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Collects every event of [stream] into a list.
List<T> record<T>(Stream<T> stream) {
  final out = <T>[];
  stream.listen(out.add);
  return out;
}
