/// Metadata for a file in the shared room directory.
class SharedFileEntry {
  const SharedFileEntry({
    required this.name,
    required this.senderId,
    required this.senderName,
    required this.sharedAt,
    required this.sizeBytes,
  });

  final String name;
  final String senderId;
  final String senderName;
  final DateTime sharedAt;
  final int sizeBytes;

  factory SharedFileEntry.fromJson(dynamic json) {
    if (json is String) {
      return SharedFileEntry(
        name: json,
        senderId: '',
        senderName: 'Unknown',
        sharedAt: DateTime.fromMillisecondsSinceEpoch(0),
        sizeBytes: 0,
      );
    }
    final map = json as Map<dynamic, dynamic>;
    final sharedAtRaw = (map['sharedAt'] ?? map['timestamp'] ?? '').toString();
    final parsedAt = DateTime.tryParse(sharedAtRaw);
    return SharedFileEntry(
      name: (map['name'] ?? '').toString(),
      senderId: (map['senderId'] ?? '').toString(),
      senderName: (map['senderName'] ?? map['senderDisplayName'] ?? 'Unknown')
          .toString(),
      sharedAt: parsedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      sizeBytes: map['sizeBytes'] is int
          ? map['sizeBytes'] as int
          : int.tryParse('${map['sizeBytes'] ?? 0}') ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'senderId': senderId,
        'senderName': senderName,
        'sharedAt': sharedAt.toUtc().toIso8601String(),
        'sizeBytes': sizeBytes,
      };
}
