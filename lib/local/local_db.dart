import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'subscription_date_calc.dart';

/// Encrypted local SQLite store used by the mobile app for offline-first
/// customer / payment / reminder data. The DB is opened with SQLCipher and a
/// per-install key kept in flutter_secure_storage (Keystore on Android,
/// Keychain on iOS).
class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  static const _dbName = 'payment_reminder.db';
  static const _dbVersion = 7;
  static const _keyAlias = 'paybell_db_key_v1';

  Database? _db;

  Future<Database> open() async {
    if (_db != null) return _db!;
    final key = await _resolveKey();
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      password: key,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      // SQLite ships with FK enforcement OFF by default. Our schema relies on
      // ON DELETE CASCADE for subscriptions(customer_id) and payments
      // (subscription_id) — without this the cascade declarations are silently
      // ignored. onConfigure runs before any other callback, so the pragma is
      // applied to the freshly-opened connection.
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
    return _db!;
  }

  Future<String> _resolveKey() async {
    const storage = FlutterSecureStorage();
    var key = await storage.read(key: _keyAlias);
    if (key == null || key.isEmpty) {
      final rng = Random.secure();
      final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
      key = base64UrlEncode(bytes);
      await storage.write(key: _keyAlias, value: key);
    }
    return key;
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE customers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        mobile TEXT NOT NULL,
        email TEXT NULL,
        address TEXT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        notes TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_customers_mobile ON customers(mobile)');

    // Plan catalog: reusable plan templates (name + amount + frequency) that a
    // subscription is created against. plan_id on subscriptions is a soft
    // reference (no FK): a subscription snapshots the plan's name/amount/
    // frequency at creation, so deleting a catalog plan never breaks it.
    batch.execute('''
      CREATE TABLE plans (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        amount REAL NOT NULL,
        frequency INTEGER NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NULL
      )
    ''');
    batch.execute('CREATE UNIQUE INDEX idx_plans_name ON plans(name COLLATE NOCASE)');

    batch.execute('''
      CREATE TABLE subscriptions (
        id TEXT PRIMARY KEY,
        customer_id TEXT NOT NULL,
        plan_id TEXT NULL,
        plan_name TEXT NOT NULL,
        amount REAL NOT NULL,
        frequency INTEGER NOT NULL,
        start_date TEXT NOT NULL,
        next_due_date TEXT NOT NULL,
        status INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NULL,
        FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_subscriptions_due ON subscriptions(next_due_date, status)');

    batch.execute('''
      CREATE TABLE payments (
        id TEXT PRIMARY KEY,
        subscription_id TEXT NOT NULL,
        amount REAL NOT NULL,
        payment_date TEXT NOT NULL,
        payment_mode INTEGER NOT NULL,
        transaction_ref TEXT NULL,
        notes TEXT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (subscription_id) REFERENCES subscriptions(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_payments_date ON payments(payment_date)');

    batch.execute('''
      CREATE TABLE reminder_history (
        id TEXT PRIMARY KEY,
        customer_id TEXT NULL,
        subscription_id TEXT NULL,
        channel INTEGER NOT NULL,
        recipient TEXT NOT NULL,
        message_body TEXT NULL,
        status TEXT NOT NULL,
        provider_message_id TEXT NULL,
        error TEXT NULL,
        sent_at TEXT NOT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_reminder_history_sent ON reminder_history(sent_at DESC)');

    batch.execute('''
      CREATE TABLE license_cache (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        license_key TEXT NOT NULL,
        device_id TEXT NOT NULL,
        status TEXT NOT NULL,
        valid_until TEXT NOT NULL,
        last_validated_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE pending_reminders (
        id TEXT PRIMARY KEY,
        customer_id TEXT NULL,
        subscription_id TEXT NULL,
        channel INTEGER NOT NULL,
        recipient TEXT NOT NULL,
        customer_name TEXT NOT NULL,
        amount REAL NOT NULL,
        due_date TEXT NOT NULL,
        scheduled_for TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        last_attempt_at TEXT NULL,
        created_at TEXT NOT NULL,
        message_body TEXT NULL,
        email_subject TEXT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_pending_scheduled ON pending_reminders(scheduled_for)');

    batch.execute('''
      CREATE TABLE app_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_reminders (
          id TEXT PRIMARY KEY,
          customer_id TEXT NULL,
          subscription_id TEXT NULL,
          channel INTEGER NOT NULL,
          recipient TEXT NOT NULL,
          customer_name TEXT NOT NULL,
          amount REAL NOT NULL,
          due_date TEXT NOT NULL,
          scheduled_for TEXT NOT NULL,
          retry_count INTEGER NOT NULL DEFAULT 0,
          last_error TEXT NULL,
          last_attempt_at TEXT NULL,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pending_scheduled ON pending_reminders(scheduled_for)');
    }
    if (oldVersion < 3) {
      // Backfill next_due_date for every existing subscription based on its
      // cumulative payments. The previous behaviour advanced next_due by one
      // full period on every recorded payment regardless of amount, so users
      // who made partial payments saw an incorrect (too far in the future)
      // next_due. This pass corrects them once; new payments after this point
      // keep next_due in sync via the recompute logic in payments_tab.
      final subs = await db.rawQuery(
          'SELECT id, start_date, frequency, amount FROM subscriptions');
      for (final s in subs) {
        final id = s['id'] as String;
        final startDate = DateTime.parse(s['start_date'] as String);
        final freq = s['frequency'] as int;
        final amount = (s['amount'] as num).toDouble();
        final paidRow = await db.rawQuery(
          'SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE subscription_id = ?',
          [id],
        );
        final totalPaid = ((paidRow.first['total'] as num?) ?? 0).toDouble();
        final newNextDue = computeNextDueFor(
          startDate: startDate,
          frequency: freq,
          amountPerCycle: amount,
          totalPaid: totalPaid,
        );
        await db.update(
          'subscriptions',
          {'next_due_date': newNextDue.toIso8601String()},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
    if (oldVersion < 4) {
      // app_meta is the cross-cutting key/value store the AuthController
      // uses to remember which org currently owns the local data — so that
      // when a different account logs in on the same device we can detect
      // it and wipe before the new user lands on a dashboard full of the
      // previous user's customers / payments / license cache.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      // SMS reminders are sent on-device via the SIM and may need to be
      // queued (no SIM, airplane mode, transient modem error). Unlike
      // WhatsApp/email — whose body is rendered server-side from the
      // customer fields — SMS bodies are produced from a user-edited
      // template; we store the rendered text alongside the queued row so a
      // later edit to the template does not retroactively change the
      // wording of an in-flight reminder.
      await db.execute(
          'ALTER TABLE pending_reminders ADD COLUMN message_body TEXT NULL');
    }
    if (oldVersion < 6) {
      // Introduce the Plan catalog. Subscriptions previously stored a free-text
      // plan_name; we now also keep a reusable Plan template and a soft
      // plan_id reference on each subscription. Backfill: create one catalog
      // Plan per distinct existing plan_name (case-insensitive), then link the
      // subscriptions to it. The subscription keeps its own name/amount/
      // frequency snapshot, so this is purely additive.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS plans (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          amount REAL NOT NULL,
          frequency INTEGER NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NULL
        )
      ''');
      await db.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_plans_name ON plans(name COLLATE NOCASE)');
      await db.execute('ALTER TABLE subscriptions ADD COLUMN plan_id TEXT NULL');

      // One Plan per distinct plan_name; first amount/frequency seen wins.
      final distinct = await db.rawQuery('''
        SELECT plan_name AS name, amount, frequency
        FROM subscriptions
        GROUP BY plan_name COLLATE NOCASE
      ''');
      final now = DateTime.now();
      for (var i = 0; i < distinct.length; i++) {
        final row = distinct[i];
        final name = (row['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) continue;
        final planId = 'p-${now.microsecondsSinceEpoch}-$i';
        await db.insert('plans', {
          'id': planId,
          'name': name,
          'amount': (row['amount'] as num?)?.toDouble() ?? 0,
          'frequency': (row['frequency'] as num?)?.toInt() ?? 1,
          'is_active': 1,
          'created_at': now.toIso8601String(),
          'updated_at': null,
        });
        await db.update(
          'subscriptions',
          {'plan_id': planId},
          where: 'plan_name = ? COLLATE NOCASE',
          whereArgs: [name],
        );
      }
    }
    if (oldVersion < 7) {
      // Email reminders are now rendered on-device from a user-editable
      // template (like SMS). Queued email reminders snapshot the rendered
      // subject here (the body reuses the existing message_body column) so an
      // offline retry sends exactly what the user saw.
      await db.execute(
          'ALTER TABLE pending_reminders ADD COLUMN email_subject TEXT NULL');
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Drops every per-user row from the local DB while preserving the schema.
  /// Called from AuthController on logout / register / login-as-different-
  /// user. The owner_org_id marker is also cleared so the next login is
  /// treated as a clean slate. Schema-level metadata (db version) survives.
  Future<void> wipeUserData() async {
    final db = await open();
    final batch = db.batch();
    // Delete in FK-friendly order (children before parents) even though we
    // also have ON DELETE CASCADE — explicit deletes avoid surprising
    // pragma states from interfering with the wipe.
    batch.delete('payments');
    batch.delete('reminder_history');
    batch.delete('pending_reminders');
    batch.delete('subscriptions');
    batch.delete('plans');
    batch.delete('customers');
    batch.delete('license_cache');
    batch.delete('app_meta', where: 'key = ?', whereArgs: ['owner_org_id']);
    await batch.commit(noResult: true);
  }

  /// Returns the orgId currently associated with the local data set, or
  /// null if no owner has been recorded (fresh install / post-wipe).
  Future<String?> readOwnerOrgId() async {
    final db = await open();
    final rows = await db.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['owner_org_id'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// Records the orgId that owns the current local data set. Subsequent
  /// logins compare against this to decide whether to wipe before settling
  /// a new session.
  Future<void> writeOwnerOrgId(String orgId) async {
    final db = await open();
    await db.insert(
      'app_meta',
      {'key': 'owner_org_id', 'value': orgId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}