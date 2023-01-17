part of sni_database;

class SembastService extends SingleChildStatefulWidget {
  final int version;
  final String databaseId;
  final Widget? child;
  final List<SembastDatabaseHandler> handlers;

  const SembastService({
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
  State<SembastService> createState() => _SembastServiceState();

  static T? find<T extends SembastDatabaseHandler>(BuildContext context) {
    final state = context.findAncestorStateOfType<_SembastServiceState>();
    if (state == null) return null;
    return state._find();
  }
}

class _SembastServiceState extends SingleChildState<SembastService> {
  late final _SembastDatabaseHelper db;

  T? _find<T extends SembastDatabaseHandler>() {
    for (final hander in db.handlers) {
      if (hander is T) {
        return hander;
      }
    }

    return SembastService.find<T>(context);
  }

  @override
  void initState() {
    super.initState();
    db = _SembastDatabaseHelper(
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

class _SembastDatabaseHelper {
  final int version;
  final String name;

  Database? db;
  final List<SembastDatabaseHandler> factories;
  final List<SembastDatabaseHandler> _handlers = [];
  List<SembastDatabaseHandler> get handlers => _handlers;

  _SembastDatabaseHelper({
    required this.name,
    required this.factories,
    required this.version,
  }) {
    for (final handerFactory in factories) {
      _handlers.add(handerFactory);
    }
  }

  Future<Database> openDatabase(
    String path, {
    int? version,
    FutureOr<dynamic> Function(Database, int, int)? onVersionChanged,
    DatabaseMode? mode,
    SembastCodec? codec,
  }) async {
    if (kIsWeb) {
      return await databaseFactoryWeb.openDatabase(
        path,
        version: version,
        onVersionChanged: onVersionChanged,
        mode: mode,
        codec: codec,
      );
    }

    final appDir = await getApplicationDocumentsDirectory();
    await appDir.create(recursive: true);
    final databasePath = pt.join(appDir.path, path);

    return await databaseFactoryIo.openDatabase(
      databasePath,
      version: version,
      onVersionChanged: onVersionChanged,
      mode: mode,
      codec: codec,
    );
  }

  bool _isOpened = false;
  Future<void> open() async {
    if (_isOpened) return;
    db = await openDatabase(
      'uid_$name.local_db',
      version: version,
      onVersionChanged: (db, oldVersion, newVersion) async {
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

abstract class SembastDatabaseHandler {
  Database? _db;
  Database? get db => _db;

  List<SembastTable> get tables => [];

  final _readyCompleter = Completer();
  void _setDatabase(Database value) {
    _db = value;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  Future get ensureReady => _readyCompleter.future;
}

enum SembastDataType {
  integer,
  text,
  real,
  dateTime,
  bytes,
}

class SembastField {
  final String name;
  final SembastDataType type;
  final bool isPrimaryKey;
  final bool isUnique;
  final bool isAutoIncrement;

  factory SembastField.primary() => SembastField._(
        name: 'id',
        type: SembastDataType.integer,
        isPrimaryKey: true,
        isAutoIncrement: true,
      );

  factory SembastField.text(
    String name, {
    bool isUnique = false,
  }) =>
      SembastField._(
        name: name,
        type: SembastDataType.text,
        isUnique: isUnique,
      );

  factory SembastField.integer(
    String name, {
    bool isUnique = false,
    bool isAutoIncrement = false,
    bool isPrimaryKey = false,
  }) =>
      SembastField._(
        name: name,
        type: SembastDataType.integer,
        isUnique: isUnique,
        isAutoIncrement: isAutoIncrement,
        isPrimaryKey: isPrimaryKey,
      );

  factory SembastField.real(
    String name, {
    bool isUnique = false,
    bool isAutoIncrement = false,
    bool isPrimaryKey = false,
  }) =>
      SembastField._(
        name: name,
        type: SembastDataType.real,
        isUnique: isUnique,
        isAutoIncrement: isAutoIncrement,
        isPrimaryKey: isPrimaryKey,
      );

  factory SembastField.dateTime(
    String name, {
    bool isUnique = false,
  }) =>
      SembastField._(
        name: name,
        type: SembastDataType.dateTime,
        isUnique: isUnique,
      );

  SembastField._({
    required this.name,
    required this.type,
    this.isPrimaryKey = false,
    this.isUnique = false,
    this.isAutoIncrement = false,
  });
}

class SembastTable {
  final String name;
  final List<SembastField> fields;

  SembastTable({
    required this.name,
    required this.fields,
  }) {
    _storeRef = stringMapStoreFactory.store(name);
  }

  Database? _db;
  late StoreRef _storeRef;

  final _readyCompleter = Completer();
  void _ready(Database db) {
    _db = db;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  Future<void> initialize({required Transaction txn}) async {
    // await _db!.transaction((txn) async {
    //   for (final field in fields) {
    //     await _storeRef.add(_db!, {field.name: ''});
    //   }
    // });
  }

  Future<List<Map<String, Object?>>> query({Finder? finder}) async {
    await _readyCompleter.future;
    final recordSnapshots = await _storeRef.find(
      _db!,
      finder: finder,
    );

    return recordSnapshots.map((e) => e.value as Map<String, Object?>).toList();
  }

  Future<void> insert(Map<String, Object?> values) async {
    await _readyCompleter.future;
    await _storeRef.add(_db!, values);
  }

  Future<void> update(
    Map<String, Object?> values, {
    required String where,
    required String whereArgs,
  }) async {
    await _readyCompleter.future;
    final finder = Finder(filter: Filter.matches(where, whereArgs));
    await _storeRef.update(
      _db!,
      values,
      finder: finder,
    );
  }

  Future<void> delete({
    String? where,
    String? whereArgs,
  }) async {
    await _readyCompleter.future;
    final finder = Finder(filter: Filter.matches(where ?? '', whereArgs ?? ''));
    await _storeRef.delete(
      _db!,
      finder: finder,
    );
  }

  Future<T> transaction<T>(Future<T> Function(Transaction txn) handler) {
    return _db!.transaction<T>(handler);
  }
}
