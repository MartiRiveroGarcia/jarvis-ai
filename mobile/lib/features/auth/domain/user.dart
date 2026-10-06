import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';

/// The signed-in account, as returned by the backend.
@immutable
class User {
  const User({required this.id, required this.email, required this.createdAt});

  /// Parses the backend's UserResponse. Throws [FormatException] if invalid.
  factory User.fromJson(JsonObject json) {
    if (json
        case {
          'id': final String id,
          'email': final String email,
          'created_at': final String createdAt,
        }
        when id.isNotEmpty && email.isNotEmpty) {
      return User(
        id: id,
        email: email,
        createdAt: DateTime.parse(createdAt).toUtc(),
      );
    }
    throw const FormatException('Invalid user in response');
  }

  final String id;
  final String email;

  /// UTC.
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      other is User &&
      other.id == id &&
      other.email == email &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, email, createdAt);

  /// Deliberately excludes the email so it does not end up in logs.
  @override
  String toString() => 'User(id: $id)';
}
