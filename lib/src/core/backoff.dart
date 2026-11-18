import 'dart:math' as math;

/// Exponential backoff with jitter and an optional attempt budget.
/// Mirrors SwiftBLEKit's `ExponentialBackoff`.
final class ExponentialBackoff {
  const ExponentialBackoff({
    this.initialDelay = const Duration(milliseconds: 500),
    this.multiplier = 2.0,
    this.maxDelay = const Duration(seconds: 30),
    this.maxAttempts = 10,
    this.jitter = 0.2,
  });

  /// Retries forever.
  static const ExponentialBackoff persistent = ExponentialBackoff(
    maxAttempts: null,
  );

  final Duration initialDelay;
  final double multiplier;
  final Duration maxDelay;

  /// Maximum number of attempts; `null` means unlimited.
  final int? maxAttempts;

  /// Fractional spread applied to each delay (0.2 = ±20%).
  final double jitter;

  static final math.Random _random = math.Random();

  /// Whether another attempt may follow [after] finished ones.
  bool allowsAttempt({required int after}) {
    final max = maxAttempts;
    return max == null || after < max;
  }

  /// The un-jittered delay before [attempt] (1-based).
  Duration baseDelay(int attempt) {
    if (attempt <= 0) return Duration.zero;
    final raw = initialDelay.inMicroseconds * math.pow(multiplier, attempt - 1);
    final capped = math.min(raw.toDouble(), maxDelay.inMicroseconds.toDouble());
    return Duration(microseconds: capped.round());
  }

  /// The jittered delay before [attempt]. [randomUnit] in 0...1 maps onto
  /// -jitter...+jitter; it defaults to a random value.
  Duration delay(int attempt, {double? randomUnit}) {
    final base = baseDelay(attempt);
    if (jitter <= 0) return base;
    final unit = randomUnit ?? _random.nextDouble();
    final spread = base.inMicroseconds * jitter;
    final offset = (unit * 2 - 1) * spread;
    final micros = math.max(0.0, base.inMicroseconds + offset);
    return Duration(microseconds: micros.round());
  }

  @override
  bool operator ==(Object other) =>
      other is ExponentialBackoff &&
      other.initialDelay == initialDelay &&
      other.multiplier == multiplier &&
      other.maxDelay == maxDelay &&
      other.maxAttempts == maxAttempts &&
      other.jitter == jitter;

  @override
  int get hashCode =>
      Object.hash(initialDelay, multiplier, maxDelay, maxAttempts, jitter);
}
