/// Returns the current time in UTC. Injected so time-dependent logic is testable.
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now().toUtc();
