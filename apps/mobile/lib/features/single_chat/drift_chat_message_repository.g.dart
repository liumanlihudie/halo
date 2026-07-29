// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'drift_chat_message_repository.dart';

// ignore_for_file: type=lint
class $SingleChatConversationsTable extends SingleChatConversations
    with TableInfo<$SingleChatConversationsTable, SingleChatConversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SingleChatConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expertIdMeta = const VerificationMeta(
    'expertId',
  );
  @override
  late final GeneratedColumn<String> expertId = GeneratedColumn<String>(
    'expert_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [conversationId, expertId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'single_chat_conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<SingleChatConversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('expert_id')) {
      context.handle(
        _expertIdMeta,
        expertId.isAcceptableOrUnknown(data['expert_id']!, _expertIdMeta),
      );
    } else if (isInserting) {
      context.missing(_expertIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  SingleChatConversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SingleChatConversation(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      expertId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}expert_id'],
      )!,
    );
  }

  @override
  $SingleChatConversationsTable createAlias(String alias) {
    return $SingleChatConversationsTable(attachedDatabase, alias);
  }
}

class SingleChatConversation extends DataClass
    implements Insertable<SingleChatConversation> {
  final String conversationId;
  final String expertId;
  const SingleChatConversation({
    required this.conversationId,
    required this.expertId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['expert_id'] = Variable<String>(expertId);
    return map;
  }

  SingleChatConversationsCompanion toCompanion(bool nullToAbsent) {
    return SingleChatConversationsCompanion(
      conversationId: Value(conversationId),
      expertId: Value(expertId),
    );
  }

  factory SingleChatConversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SingleChatConversation(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      expertId: serializer.fromJson<String>(json['expertId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'expertId': serializer.toJson<String>(expertId),
    };
  }

  SingleChatConversation copyWith({String? conversationId, String? expertId}) =>
      SingleChatConversation(
        conversationId: conversationId ?? this.conversationId,
        expertId: expertId ?? this.expertId,
      );
  SingleChatConversation copyWithCompanion(
    SingleChatConversationsCompanion data,
  ) {
    return SingleChatConversation(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      expertId: data.expertId.present ? data.expertId.value : this.expertId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SingleChatConversation(')
          ..write('conversationId: $conversationId, ')
          ..write('expertId: $expertId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, expertId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SingleChatConversation &&
          other.conversationId == this.conversationId &&
          other.expertId == this.expertId);
}

class SingleChatConversationsCompanion
    extends UpdateCompanion<SingleChatConversation> {
  final Value<String> conversationId;
  final Value<String> expertId;
  final Value<int> rowid;
  const SingleChatConversationsCompanion({
    this.conversationId = const Value.absent(),
    this.expertId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SingleChatConversationsCompanion.insert({
    required String conversationId,
    required String expertId,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       expertId = Value(expertId);
  static Insertable<SingleChatConversation> custom({
    Expression<String>? conversationId,
    Expression<String>? expertId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (expertId != null) 'expert_id': expertId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SingleChatConversationsCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? expertId,
    Value<int>? rowid,
  }) {
    return SingleChatConversationsCompanion(
      conversationId: conversationId ?? this.conversationId,
      expertId: expertId ?? this.expertId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (expertId.present) {
      map['expert_id'] = Variable<String>(expertId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SingleChatConversationsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('expertId: $expertId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SingleChatMessagesTable extends SingleChatMessages
    with TableInfo<$SingleChatMessagesTable, SingleChatMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SingleChatMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _storageRevisionMeta = const VerificationMeta(
    'storageRevision',
  );
  @override
  late final GeneratedColumn<int> storageRevision = GeneratedColumn<int>(
    'storage_revision',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _projectionJsonMeta = const VerificationMeta(
    'projectionJson',
  );
  @override
  late final GeneratedColumn<String> projectionJson = GeneratedColumn<String>(
    'projection_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _projectionSha256Meta = const VerificationMeta(
    'projectionSha256',
  );
  @override
  late final GeneratedColumn<String> projectionSha256 = GeneratedColumn<String>(
    'projection_sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ownerGenerationMeta = const VerificationMeta(
    'ownerGeneration',
  );
  @override
  late final GeneratedColumn<int> ownerGeneration = GeneratedColumn<int>(
    'owner_generation',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    storageRevision,
    conversationId,
    messageId,
    projectionJson,
    projectionSha256,
    ownerId,
    ownerGeneration,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'single_chat_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<SingleChatMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('storage_revision')) {
      context.handle(
        _storageRevisionMeta,
        storageRevision.isAcceptableOrUnknown(
          data['storage_revision']!,
          _storageRevisionMeta,
        ),
      );
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('projection_json')) {
      context.handle(
        _projectionJsonMeta,
        projectionJson.isAcceptableOrUnknown(
          data['projection_json']!,
          _projectionJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_projectionJsonMeta);
    }
    if (data.containsKey('projection_sha256')) {
      context.handle(
        _projectionSha256Meta,
        projectionSha256.isAcceptableOrUnknown(
          data['projection_sha256']!,
          _projectionSha256Meta,
        ),
      );
    } else if (isInserting) {
      context.missing(_projectionSha256Meta);
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('owner_generation')) {
      context.handle(
        _ownerGenerationMeta,
        ownerGeneration.isAcceptableOrUnknown(
          data['owner_generation']!,
          _ownerGenerationMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {storageRevision};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {conversationId, messageId},
  ];
  @override
  SingleChatMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SingleChatMessage(
      storageRevision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}storage_revision'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      projectionJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}projection_json'],
      )!,
      projectionSha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}projection_sha256'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      ownerGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}owner_generation'],
      ),
    );
  }

  @override
  $SingleChatMessagesTable createAlias(String alias) {
    return $SingleChatMessagesTable(attachedDatabase, alias);
  }
}

class SingleChatMessage extends DataClass
    implements Insertable<SingleChatMessage> {
  final int storageRevision;
  final String conversationId;
  final String messageId;
  final String projectionJson;
  final String projectionSha256;
  final String? ownerId;
  final int? ownerGeneration;
  const SingleChatMessage({
    required this.storageRevision,
    required this.conversationId,
    required this.messageId,
    required this.projectionJson,
    required this.projectionSha256,
    this.ownerId,
    this.ownerGeneration,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['storage_revision'] = Variable<int>(storageRevision);
    map['conversation_id'] = Variable<String>(conversationId);
    map['message_id'] = Variable<String>(messageId);
    map['projection_json'] = Variable<String>(projectionJson);
    map['projection_sha256'] = Variable<String>(projectionSha256);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    if (!nullToAbsent || ownerGeneration != null) {
      map['owner_generation'] = Variable<int>(ownerGeneration);
    }
    return map;
  }

  SingleChatMessagesCompanion toCompanion(bool nullToAbsent) {
    return SingleChatMessagesCompanion(
      storageRevision: Value(storageRevision),
      conversationId: Value(conversationId),
      messageId: Value(messageId),
      projectionJson: Value(projectionJson),
      projectionSha256: Value(projectionSha256),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      ownerGeneration: ownerGeneration == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerGeneration),
    );
  }

  factory SingleChatMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SingleChatMessage(
      storageRevision: serializer.fromJson<int>(json['storageRevision']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      projectionJson: serializer.fromJson<String>(json['projectionJson']),
      projectionSha256: serializer.fromJson<String>(json['projectionSha256']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      ownerGeneration: serializer.fromJson<int?>(json['ownerGeneration']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'storageRevision': serializer.toJson<int>(storageRevision),
      'conversationId': serializer.toJson<String>(conversationId),
      'messageId': serializer.toJson<String>(messageId),
      'projectionJson': serializer.toJson<String>(projectionJson),
      'projectionSha256': serializer.toJson<String>(projectionSha256),
      'ownerId': serializer.toJson<String?>(ownerId),
      'ownerGeneration': serializer.toJson<int?>(ownerGeneration),
    };
  }

  SingleChatMessage copyWith({
    int? storageRevision,
    String? conversationId,
    String? messageId,
    String? projectionJson,
    String? projectionSha256,
    Value<String?> ownerId = const Value.absent(),
    Value<int?> ownerGeneration = const Value.absent(),
  }) => SingleChatMessage(
    storageRevision: storageRevision ?? this.storageRevision,
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    projectionJson: projectionJson ?? this.projectionJson,
    projectionSha256: projectionSha256 ?? this.projectionSha256,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    ownerGeneration: ownerGeneration.present
        ? ownerGeneration.value
        : this.ownerGeneration,
  );
  SingleChatMessage copyWithCompanion(SingleChatMessagesCompanion data) {
    return SingleChatMessage(
      storageRevision: data.storageRevision.present
          ? data.storageRevision.value
          : this.storageRevision,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      projectionJson: data.projectionJson.present
          ? data.projectionJson.value
          : this.projectionJson,
      projectionSha256: data.projectionSha256.present
          ? data.projectionSha256.value
          : this.projectionSha256,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      ownerGeneration: data.ownerGeneration.present
          ? data.ownerGeneration.value
          : this.ownerGeneration,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SingleChatMessage(')
          ..write('storageRevision: $storageRevision, ')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('projectionJson: $projectionJson, ')
          ..write('projectionSha256: $projectionSha256, ')
          ..write('ownerId: $ownerId, ')
          ..write('ownerGeneration: $ownerGeneration')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    storageRevision,
    conversationId,
    messageId,
    projectionJson,
    projectionSha256,
    ownerId,
    ownerGeneration,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SingleChatMessage &&
          other.storageRevision == this.storageRevision &&
          other.conversationId == this.conversationId &&
          other.messageId == this.messageId &&
          other.projectionJson == this.projectionJson &&
          other.projectionSha256 == this.projectionSha256 &&
          other.ownerId == this.ownerId &&
          other.ownerGeneration == this.ownerGeneration);
}

class SingleChatMessagesCompanion extends UpdateCompanion<SingleChatMessage> {
  final Value<int> storageRevision;
  final Value<String> conversationId;
  final Value<String> messageId;
  final Value<String> projectionJson;
  final Value<String> projectionSha256;
  final Value<String?> ownerId;
  final Value<int?> ownerGeneration;
  const SingleChatMessagesCompanion({
    this.storageRevision = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.projectionJson = const Value.absent(),
    this.projectionSha256 = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.ownerGeneration = const Value.absent(),
  });
  SingleChatMessagesCompanion.insert({
    this.storageRevision = const Value.absent(),
    required String conversationId,
    required String messageId,
    required String projectionJson,
    required String projectionSha256,
    this.ownerId = const Value.absent(),
    this.ownerGeneration = const Value.absent(),
  }) : conversationId = Value(conversationId),
       messageId = Value(messageId),
       projectionJson = Value(projectionJson),
       projectionSha256 = Value(projectionSha256);
  static Insertable<SingleChatMessage> custom({
    Expression<int>? storageRevision,
    Expression<String>? conversationId,
    Expression<String>? messageId,
    Expression<String>? projectionJson,
    Expression<String>? projectionSha256,
    Expression<String>? ownerId,
    Expression<int>? ownerGeneration,
  }) {
    return RawValuesInsertable({
      if (storageRevision != null) 'storage_revision': storageRevision,
      if (conversationId != null) 'conversation_id': conversationId,
      if (messageId != null) 'message_id': messageId,
      if (projectionJson != null) 'projection_json': projectionJson,
      if (projectionSha256 != null) 'projection_sha256': projectionSha256,
      if (ownerId != null) 'owner_id': ownerId,
      if (ownerGeneration != null) 'owner_generation': ownerGeneration,
    });
  }

  SingleChatMessagesCompanion copyWith({
    Value<int>? storageRevision,
    Value<String>? conversationId,
    Value<String>? messageId,
    Value<String>? projectionJson,
    Value<String>? projectionSha256,
    Value<String?>? ownerId,
    Value<int?>? ownerGeneration,
  }) {
    return SingleChatMessagesCompanion(
      storageRevision: storageRevision ?? this.storageRevision,
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      projectionJson: projectionJson ?? this.projectionJson,
      projectionSha256: projectionSha256 ?? this.projectionSha256,
      ownerId: ownerId ?? this.ownerId,
      ownerGeneration: ownerGeneration ?? this.ownerGeneration,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (storageRevision.present) {
      map['storage_revision'] = Variable<int>(storageRevision.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (projectionJson.present) {
      map['projection_json'] = Variable<String>(projectionJson.value);
    }
    if (projectionSha256.present) {
      map['projection_sha256'] = Variable<String>(projectionSha256.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (ownerGeneration.present) {
      map['owner_generation'] = Variable<int>(ownerGeneration.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SingleChatMessagesCompanion(')
          ..write('storageRevision: $storageRevision, ')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('projectionJson: $projectionJson, ')
          ..write('projectionSha256: $projectionSha256, ')
          ..write('ownerId: $ownerId, ')
          ..write('ownerGeneration: $ownerGeneration')
          ..write(')'))
        .toString();
  }
}

abstract class _$_SingleChatDatabase extends GeneratedDatabase {
  _$_SingleChatDatabase(QueryExecutor e) : super(e);
  $_SingleChatDatabaseManager get managers => $_SingleChatDatabaseManager(this);
  late final $SingleChatConversationsTable singleChatConversations =
      $SingleChatConversationsTable(this);
  late final $SingleChatMessagesTable singleChatMessages =
      $SingleChatMessagesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    singleChatConversations,
    singleChatMessages,
  ];
}

typedef $$SingleChatConversationsTableCreateCompanionBuilder =
    SingleChatConversationsCompanion Function({
      required String conversationId,
      required String expertId,
      Value<int> rowid,
    });
typedef $$SingleChatConversationsTableUpdateCompanionBuilder =
    SingleChatConversationsCompanion Function({
      Value<String> conversationId,
      Value<String> expertId,
      Value<int> rowid,
    });

class $$SingleChatConversationsTableFilterComposer
    extends Composer<_$_SingleChatDatabase, $SingleChatConversationsTable> {
  $$SingleChatConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get expertId => $composableBuilder(
    column: $table.expertId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SingleChatConversationsTableOrderingComposer
    extends Composer<_$_SingleChatDatabase, $SingleChatConversationsTable> {
  $$SingleChatConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get expertId => $composableBuilder(
    column: $table.expertId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SingleChatConversationsTableAnnotationComposer
    extends Composer<_$_SingleChatDatabase, $SingleChatConversationsTable> {
  $$SingleChatConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get expertId =>
      $composableBuilder(column: $table.expertId, builder: (column) => column);
}

class $$SingleChatConversationsTableTableManager
    extends
        RootTableManager<
          _$_SingleChatDatabase,
          $SingleChatConversationsTable,
          SingleChatConversation,
          $$SingleChatConversationsTableFilterComposer,
          $$SingleChatConversationsTableOrderingComposer,
          $$SingleChatConversationsTableAnnotationComposer,
          $$SingleChatConversationsTableCreateCompanionBuilder,
          $$SingleChatConversationsTableUpdateCompanionBuilder,
          (
            SingleChatConversation,
            BaseReferences<
              _$_SingleChatDatabase,
              $SingleChatConversationsTable,
              SingleChatConversation
            >,
          ),
          SingleChatConversation,
          PrefetchHooks Function()
        > {
  $$SingleChatConversationsTableTableManager(
    _$_SingleChatDatabase db,
    $SingleChatConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SingleChatConversationsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$SingleChatConversationsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$SingleChatConversationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> expertId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SingleChatConversationsCompanion(
                conversationId: conversationId,
                expertId: expertId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String expertId,
                Value<int> rowid = const Value.absent(),
              }) => SingleChatConversationsCompanion.insert(
                conversationId: conversationId,
                expertId: expertId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SingleChatConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$_SingleChatDatabase,
      $SingleChatConversationsTable,
      SingleChatConversation,
      $$SingleChatConversationsTableFilterComposer,
      $$SingleChatConversationsTableOrderingComposer,
      $$SingleChatConversationsTableAnnotationComposer,
      $$SingleChatConversationsTableCreateCompanionBuilder,
      $$SingleChatConversationsTableUpdateCompanionBuilder,
      (
        SingleChatConversation,
        BaseReferences<
          _$_SingleChatDatabase,
          $SingleChatConversationsTable,
          SingleChatConversation
        >,
      ),
      SingleChatConversation,
      PrefetchHooks Function()
    >;
typedef $$SingleChatMessagesTableCreateCompanionBuilder =
    SingleChatMessagesCompanion Function({
      Value<int> storageRevision,
      required String conversationId,
      required String messageId,
      required String projectionJson,
      required String projectionSha256,
      Value<String?> ownerId,
      Value<int?> ownerGeneration,
    });
typedef $$SingleChatMessagesTableUpdateCompanionBuilder =
    SingleChatMessagesCompanion Function({
      Value<int> storageRevision,
      Value<String> conversationId,
      Value<String> messageId,
      Value<String> projectionJson,
      Value<String> projectionSha256,
      Value<String?> ownerId,
      Value<int?> ownerGeneration,
    });

class $$SingleChatMessagesTableFilterComposer
    extends Composer<_$_SingleChatDatabase, $SingleChatMessagesTable> {
  $$SingleChatMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get storageRevision => $composableBuilder(
    column: $table.storageRevision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get projectionJson => $composableBuilder(
    column: $table.projectionJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get projectionSha256 => $composableBuilder(
    column: $table.projectionSha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ownerGeneration => $composableBuilder(
    column: $table.ownerGeneration,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SingleChatMessagesTableOrderingComposer
    extends Composer<_$_SingleChatDatabase, $SingleChatMessagesTable> {
  $$SingleChatMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get storageRevision => $composableBuilder(
    column: $table.storageRevision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get projectionJson => $composableBuilder(
    column: $table.projectionJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get projectionSha256 => $composableBuilder(
    column: $table.projectionSha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ownerGeneration => $composableBuilder(
    column: $table.ownerGeneration,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SingleChatMessagesTableAnnotationComposer
    extends Composer<_$_SingleChatDatabase, $SingleChatMessagesTable> {
  $$SingleChatMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get storageRevision => $composableBuilder(
    column: $table.storageRevision,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get projectionJson => $composableBuilder(
    column: $table.projectionJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get projectionSha256 => $composableBuilder(
    column: $table.projectionSha256,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<int> get ownerGeneration => $composableBuilder(
    column: $table.ownerGeneration,
    builder: (column) => column,
  );
}

class $$SingleChatMessagesTableTableManager
    extends
        RootTableManager<
          _$_SingleChatDatabase,
          $SingleChatMessagesTable,
          SingleChatMessage,
          $$SingleChatMessagesTableFilterComposer,
          $$SingleChatMessagesTableOrderingComposer,
          $$SingleChatMessagesTableAnnotationComposer,
          $$SingleChatMessagesTableCreateCompanionBuilder,
          $$SingleChatMessagesTableUpdateCompanionBuilder,
          (
            SingleChatMessage,
            BaseReferences<
              _$_SingleChatDatabase,
              $SingleChatMessagesTable,
              SingleChatMessage
            >,
          ),
          SingleChatMessage,
          PrefetchHooks Function()
        > {
  $$SingleChatMessagesTableTableManager(
    _$_SingleChatDatabase db,
    $SingleChatMessagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SingleChatMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SingleChatMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SingleChatMessagesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> storageRevision = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<String> projectionJson = const Value.absent(),
                Value<String> projectionSha256 = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<int?> ownerGeneration = const Value.absent(),
              }) => SingleChatMessagesCompanion(
                storageRevision: storageRevision,
                conversationId: conversationId,
                messageId: messageId,
                projectionJson: projectionJson,
                projectionSha256: projectionSha256,
                ownerId: ownerId,
                ownerGeneration: ownerGeneration,
              ),
          createCompanionCallback:
              ({
                Value<int> storageRevision = const Value.absent(),
                required String conversationId,
                required String messageId,
                required String projectionJson,
                required String projectionSha256,
                Value<String?> ownerId = const Value.absent(),
                Value<int?> ownerGeneration = const Value.absent(),
              }) => SingleChatMessagesCompanion.insert(
                storageRevision: storageRevision,
                conversationId: conversationId,
                messageId: messageId,
                projectionJson: projectionJson,
                projectionSha256: projectionSha256,
                ownerId: ownerId,
                ownerGeneration: ownerGeneration,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SingleChatMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$_SingleChatDatabase,
      $SingleChatMessagesTable,
      SingleChatMessage,
      $$SingleChatMessagesTableFilterComposer,
      $$SingleChatMessagesTableOrderingComposer,
      $$SingleChatMessagesTableAnnotationComposer,
      $$SingleChatMessagesTableCreateCompanionBuilder,
      $$SingleChatMessagesTableUpdateCompanionBuilder,
      (
        SingleChatMessage,
        BaseReferences<
          _$_SingleChatDatabase,
          $SingleChatMessagesTable,
          SingleChatMessage
        >,
      ),
      SingleChatMessage,
      PrefetchHooks Function()
    >;

class $_SingleChatDatabaseManager {
  final _$_SingleChatDatabase _db;
  $_SingleChatDatabaseManager(this._db);
  $$SingleChatConversationsTableTableManager get singleChatConversations =>
      $$SingleChatConversationsTableTableManager(
        _db,
        _db.singleChatConversations,
      );
  $$SingleChatMessagesTableTableManager get singleChatMessages =>
      $$SingleChatMessagesTableTableManager(_db, _db.singleChatMessages);
}
