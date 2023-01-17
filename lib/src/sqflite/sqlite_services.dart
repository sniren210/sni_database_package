part of sni_database;

class SQLiteService extends SingleChildStatefulWidget {
  final int version;
  final String databaseId;
  final Widget? child;
  final List<SQLiteDatabaseHandler> handlers;

  const SQLiteService({
    Key? key,
    this.child,
    this.databaseId = 'local',
    this.version = 1,
    required this.handlers,
  }) : super(
          key: key,
          child: child,
        );

  @override
  State<SQLiteService> createState() => _SQLiteServiceState();

  static T? find<T extends SQLiteDatabaseHandler>(BuildContext context) {
    final state = context.findAncestorStateOfType<_SQLiteServiceState>();
    if (state == null) return null;
    return state._find();
  }
}

class _SQLiteServiceState extends SingleChildState<SQLiteService> {
  late final _SQLiteDatabaseHelper db;

  T? _find<T extends SQLiteDatabaseHandler>() {
    for (final hander in db.handlers) {
      if (hander is T) {
        return hander;
      }
    }

    return SQLiteService.find<T>(context);
  }

  @override
  void initState() {
    super.initState();
    db = _SQLiteDatabaseHelper(
      name: widget.databaseId,
      factories: widget.handlers,
      version: widget.version,
    );
    db.open();
  }

  @override
  void dispose() {
    db.dispose();
    super.dispose();
  }

  @override
  Widget buildWithChild(BuildContext context, Widget? child) {
    return child ?? Container();
  }
}

class _SQLiteDatabaseHelper {
  final int version;
  final String name;

  Database? db;
  final List<SQLiteDatabaseHandler> factories;
  final List<SQLiteDatabaseHandler> _handlers = [];
  List<SQLiteDatabaseHandler> get handlers => _handlers;

  _SQLiteDatabaseHelper({
    required this.name,
    required this.factories,
    required this.version,
  }) {
    for (final handerFactory in factories) {
      _handlers.add(handerFactory);
    }
  }

  bool _isOpened = false;
  Future<void> open() async {
    if (_isOpened) return;
    db = await openDatabase(
      'uid_$name.local_db',
      version: version,
      onUpgrade: (db, oldVersion, newVersion) async {
        await db.transaction((txn) async {
          for (final handler in _handlers) {
            for (final table in handler.tables) {
              table._db = db;
              await table.initialize(txn: txn);
            }
          }
        });
      },
    );

    for (final handler in _handlers) {
      handler._setDatabase(db!);
      for (final table in handler.tables) {
        table._ready(db!);
      }
    }

    _isOpened = true;
  }

  void dispose() {
    if (!_isOpened) return;
    db?.close();
  }
}

abstract class SQLiteDatabaseHandler {
  Database? _db;
  Database? get db => _db;

  List<SQLiteTable> get tables => [];

  final _readyCompleter = Completer();
  void _setDatabase(Database value) {
    _db = value;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  Future get ensureReady => _readyCompleter.future;
}

enum SQLiteDataType {
  integer,
  text,
  real,
  dateTime,
  bytes,
}

class SQLiteField {
  final String name;
  final SQLiteDataType type;
  final bool isPrimaryKey;
  final bool isUnique;
  final bool isAutoIncrement;

  factory SQLiteField.primary() => SQLiteField._(
        name: 'id',
        type: SQLiteDataType.integer,
        isPrimaryKey: true,
        isAutoIncrement: true,
      );

  factory SQLiteField.text(
    String name, {
    bool isUnique = false,
  }) =>
      SQLiteField._(
        name: name,
        type: SQLiteDataType.text,
        isUnique: isUnique,
      );

  factory SQLiteField.integer(
    String name, {
    bool isUnique = false,
    bool isAutoIncrement = false,
    bool isPrimaryKey = false,
  }) =>
      SQLiteField._(
        name: name,
        type: SQLiteDataType.integer,
        isUnique: isUnique,
        isAutoIncrement: isAutoIncrement,
        isPrimaryKey: isPrimaryKey,
      );

  factory SQLiteField.real(
    String name, {
    bool isUnique = false,
    bool isAutoIncrement = false,
    bool isPrimaryKey = false,
  }) =>
      SQLiteField._(
        name: name,
        type: SQLiteDataType.real,
        isUnique: isUnique,
        isAutoIncrement: isAutoIncrement,
        isPrimaryKey: isPrimaryKey,
      );

  factory SQLiteField.dateTime(
    String name, {
    bool isUnique = false,
  }) =>
      SQLiteField._(
        name: name,
        type: SQLiteDataType.dateTime,
        isUnique: isUnique,
      );

  SQLiteField._({
    required this.name,
    required this.type,
    this.isPrimaryKey = false,
    this.isUnique = false,
    this.isAutoIncrement = false,
  });

  String get _commandText {
    final buffer = StringBuffer();
    buffer.write(name);
    switch (type) {
      case SQLiteDataType.text:
        buffer.write(' TEXT');
        break;

      case SQLiteDataType.integer:
        buffer.write(' INTEGER');
        break;

      case SQLiteDataType.real:
        buffer.write(' REAL');
        break;

      case SQLiteDataType.dateTime:
        buffer.write(' INTEGER');
        break;

      case SQLiteDataType.bytes:
        buffer.write(' BLOB');
        break;
    }

    if (isPrimaryKey) {
      buffer.write(' PRIMARY KEY');
    }

    if (isAutoIncrement) {
      buffer.write(' AUTOINCREMENT');
    }

    if (isUnique) {
      buffer.write(' UNIQUE');
    }

    return buffer.toString();
  }
}

class SQLiteTable {
  final String name;
  final List<SQLiteField> fields;

  SQLiteTable({
    required this.name,
    required this.fields,
  });

  Database? _db;
  final _readyCompleter = Completer();
  void _ready(Database db) {
    _db = db;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  Future<void> initialize({required Transaction txn}) async {
    final buffer = StringBuffer();

    buffer.write('CREATE TABLE IF NOT EXISTS $name (');
    buffer.write(fields.map((e) => e._commandText).join(', '));
    buffer.write(')');

    await txn.execute(buffer.toString());

    final sql = 'PRAGMA table_info($name)';
    final records = await txn.rawQuery(sql);
    final currentFields = records.map((e) => e['name'] as String).toList();
    for (final field in fields) {
      if (!currentFields.contains(field.name)) {
        final sql = 'ALTER TABLE $name ADD ${field._commandText}';
        await txn.execute(sql);
      }
    }
  }

  Future<List<Map<String, Object?>>> query({
    bool? distinct,
    List<String>? columns,
    String? where,
    List<dynamic>? whereArgs,
    String? groupBy,
    String? orderBy,
    String? having,
    int? limit,
    int? offset,
  }) async {
    await _readyCompleter.future;
    return _db!.query(
      name,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      having: having,
      groupBy: groupBy,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  Future<int> insert(Map<String, Object?> values) async {
    return await _db?.insert(name, values) ?? 0;
  }

  Future<int> update(
    Map<String, Object?> values, {
    String? where,
    List<dynamic>? whereArgs,
  }) async {
    await _readyCompleter.future;
    return _db!.update(
      name,
      values,
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<int> delete({
    String? where,
    List<dynamic>? whereArgs,
  }) async {
    await _readyCompleter.future;
    return _db!.delete(
      name,
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<T> transaction<T>(Future<T> Function(Transaction txn) handler) {
    return _db!.transaction<T>(handler);
  }
}
