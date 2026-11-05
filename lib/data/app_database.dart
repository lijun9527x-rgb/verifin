import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite_common/sqlite_api.dart';

import '../app/models/category_keys.dart';
import '../app/models/ledger_book.dart';
import 'database_factory.dart';

/// Veri Fin 本地 SQLite 数据库。负责建表、版本迁移与连接持有。
///
/// 具体的按类型读写在 [LedgerRepository]。数据库只承载「账目」类核心数据；
/// 偏好类小数据（主题、触感、面板配置、资产排序等）仍保留在 KV。
class AppDatabase {
  AppDatabase._(this.db);

  /// 底层 sqflite 连接，供仓储层执行 SQL。
  final Database db;

  static const String defaultDatabaseName = 'verifin.db';
  static const int schemaVersion = 21;

  /// 打开（或创建）数据库。测试通过 [factory]/[path] 注入 ffi 与内存路径；
  /// 真实平台留空则由 [resolveDatabaseFactory]/[resolveDatabasePath] 决定。
  static Future<AppDatabase> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final resolvedFactory = factory ?? await resolveDatabaseFactory();
    final resolvedPath = path ?? await resolveDatabasePath(defaultDatabaseName);
    final database = await resolvedFactory.openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(database);
  }

  Future<void> close() => db.close();

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    for (final statement in _schemaCurrent) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  /// 版本迁移注册表：键 N 表示「升到 vN」的迁移段（v(N-1) → vN）。[_onUpgrade]
  /// 按 (oldVersion, newVersion] 升序逐段执行；段与段的顺序依赖（如 v10 去重
  /// 依赖 v7 已建 recurring_rules 表）由升序执行天然保证。
  ///
  /// 修改表结构 = 提升 [schemaVersion] + 同步 [_schemaCurrent] + 在此注册新段。
  /// **勿改动历史段**——存量用户升级时仍会按序经过它们。测试经 [migrations]
  /// 访问本表构造任意中间版本库（见 test/migration_matrix_test.dart 的迁移矩阵）。
  static final Map<int, Future<void> Function(Database db)> _migrations =
      <int, Future<void> Function(Database db)>{
        2: _migrateToV2,
        3: _migrateToV3,
        4: _migrateToV4,
        5: _migrateToV5,
        6: _migrateToV6,
        7: _migrateToV7,
        8: _migrateToV8,
        9: _migrateToV9,
        10: _migrateToV10,
        11: _migrateToV11,
        12: _migrateToV12,
        13: _migrateToV13,
        14: _migrateToV14,
        15: _migrateToV15,
        16: _migrateToV16,
        17: _migrateToV17,
        18: _migrateToV18,
        19: _migrateToV19,
        20: _migrateToV20,
        21: _migrateToV21,
      };

  /// 只读暴露迁移注册表，供迁移矩阵测试把库推进到任意中间版本。生产代码勿用。
  @visibleForTesting
  static Map<int, Future<void> Function(Database db)> get migrations =>
      Map<int, Future<void> Function(Database db)>.unmodifiable(_migrations);

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    for (var version = oldVersion + 1; version <= newVersion; version++) {
      final migrate = _migrations[version];
      if (migrate == null) {
        // 提升了 schemaVersion 却忘了注册迁移段：宁可升级即刻失败，也不能
        // 静默跳段留下残缺 schema（后续读写会以更隐蔽的方式坏）。
        throw StateError('缺少升级到 v$version 的迁移段，需在 _migrations 注册');
      }
      await migrate(db);
    }
  }

  static const String _assetSnapshotsTable = '''
    CREATE TABLE asset_month_snapshots (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      payload TEXT NOT NULL
    )
  ''';

  /// v20 → v21：外币资产可手填本位币金额，资产汇总不再强制要求维护汇率。
  static Future<void> _migrateToV21(Database db) async {
    await db.execute('ALTER TABLE accounts ADD COLUMN base_valuation REAL');
  }

  static Future<void> _migrateToV20(Database db) async {
    await db.execute(
      "ALTER TABLE accounts ADD COLUMN asset_class TEXT NOT NULL DEFAULT 'other'",
    );
    await db.execute(_assetSnapshotsTable);
  }

  /// v1 → v2：分类支持多级树形结构，新增可空的 parent_id 列（顶级为 NULL）。
  static Future<void> _migrateToV2(Database db) async {
    await db.execute('ALTER TABLE categories ADD COLUMN parent_id TEXT');
  }

  /// v2 → v3：标签系统。新增 tags 表；交易新增可空 tag_ids 列（JSON 数组）。
  static Future<void> _migrateToV3(Database db) async {
    await db.execute('ALTER TABLE entries ADD COLUMN tag_ids TEXT');
    await db.execute('''
      CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      )
    ''');
  }

  /// v3 → v4：图片附件。独立表，按 entry_id 关联，data_url 存压缩 JPEG。
  static Future<void> _migrateToV4(Database db) async {
    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        entry_id TEXT NOT NULL,
        data_url TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_attachments_entry ON attachments (entry_id)',
    );
  }

  /// v4 → v5：转账手续费。交易新增 fee 列，默认 0。
  static Future<void> _migrateToV5(Database db) async {
    await db.execute(
      'ALTER TABLE entries ADD COLUMN fee REAL NOT NULL DEFAULT 0',
    );
  }

  /// v5 → v6：报销/退款。交易新增待报销标记与已冲抵金额。
  static Future<void> _migrateToV6(Database db) async {
    await db.execute(
      'ALTER TABLE entries ADD COLUMN reimbursable INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE entries ADD COLUMN refunded_amount REAL NOT NULL DEFAULT 0',
    );
  }

  /// v6 → v7：周期记账规则表。
  static Future<void> _migrateToV7(Database db) async {
    await db.execute(_recurringRulesTableV7);
  }

  /// v7 → v8：信用卡账单日/还款日（可选）。
  static Future<void> _migrateToV8(Database db) async {
    await db.execute('ALTER TABLE accounts ADD COLUMN statement_day INTEGER');
    await db.execute('ALTER TABLE accounts ADD COLUMN due_day INTEGER');
  }

  /// v8 → v9：按日预算维度。键为 `bookId:yyyy-MM-dd`。
  static Future<void> _migrateToV9(Database db) async {
    await db.execute(_dailyBudgetsTable);
  }

  /// v9 → v10：分类唯一性约束。历史/异构备份可能带入重复同名分类（「幽灵分类」根因），
  /// 先按 (label,type,IFNULL(parent_id,'')) 去重（交易/周期规则/子分类引用改指向保留者、
  /// 删掉重复），再建唯一索引。**必须先去重再建索引**，否则 CREATE UNIQUE INDEX 会因已有
  /// 重复行失败。悬空引用/孤儿 parentId 不违反唯一性、由 controller 载入时的 _healCategoryData
  /// 处理，此处只管重复行。
  static Future<void> _migrateToV10(Database db) async {
    // 真实库自 v1 起必有 categories/entries；recurring_rules 由 v7 段保证在前。
    // 判存在只为兼容迁移测试的最小桩库，并顺带抵御异常损坏的安装。
    if (await _tableExists(db, 'categories')) {
      await _dedupeCategories(db);
      await db.execute(_categoriesUniqueIndex);
    }
  }

  /// v10 → v11：完整卡号（信用卡/储蓄卡）与信用额度（信用卡/信用账户，可空）。
  /// 判 accounts 存在只为兼容迁移测试的最小桩库（真实库自 v1 起必有 accounts）。
  static Future<void> _migrateToV11(Database db) async {
    if (!await _tableExists(db, 'accounts')) {
      return;
    }
    await db.execute(
      "ALTER TABLE accounts ADD COLUMN card_number TEXT NOT NULL DEFAULT ''",
    );
    await db.execute('ALTER TABLE accounts ADD COLUMN credit_limit REAL');
  }

  /// v11 → v12：「后四位跟随完整卡号」开关持久化。旧账户默认 0（不跟随），
  /// 保留其可能手填的后四位、不因跟随空卡号被冲成空。
  static Future<void> _migrateToV12(Database db) async {
    if (!await _tableExists(db, 'accounts')) {
      return;
    }
    await db.execute(
      'ALTER TABLE accounts ADD COLUMN card_last4_follows INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// v12 → v13：退款独立条目。交易新增 refund_of（指向原支出，退款条目专用）与
  /// settled_at（到账日期毫秒，NULL=待到账）。历史 refunded_amount 标量在 controller
  /// 载入时的 _syncRefundData() 里合成为已到账退款条目并作缓存重算，此处只加列。
  /// 判 entries 存在只为兼容迁移测试的最小桩库（真实库自 v1 起必有 entries）。
  static Future<void> _migrateToV13(Database db) async {
    if (!await _tableExists(db, 'entries')) {
      return;
    }
    await db.execute('ALTER TABLE entries ADD COLUMN refund_of TEXT');
    await db.execute('ALTER TABLE entries ADD COLUMN settled_at INTEGER');
  }

  /// v13 → v14：离线多币种。本位币/账户币种、交易与周期规则的冻结金额，以及
  /// 按账本和生效日维护的本地汇率表。旧数据的数字不换算，只按 CNY 原样重解释。
  static Future<void> _migrateToV14(Database db) async {
    if (await _tableExists(db, 'ledger_books')) {
      await db.execute(
        "ALTER TABLE ledger_books ADD COLUMN base_currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
      await db.execute(
        "ALTER TABLE ledger_books ADD COLUMN currency_setup_status TEXT NOT NULL DEFAULT 'legacyUnconfirmed'",
      );
    }
    if (await _tableExists(db, 'accounts')) {
      await db.execute(
        "ALTER TABLE accounts ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
    }
    if (await _tableExists(db, 'entries')) {
      await db.execute(
        "ALTER TABLE entries ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
      await db.execute('ALTER TABLE entries ADD COLUMN account_amount REAL');
      await db.execute('ALTER TABLE entries ADD COLUMN to_account_amount REAL');
      await db.execute(
        'ALTER TABLE entries ADD COLUMN base_amount REAL NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE entries ADD COLUMN conversion_source TEXT NOT NULL DEFAULT 'legacy'",
      );
      // 条件判断只为兼容历史迁移的最小桩库；真实 entries 自 v1 起字段完整。
      if (await _columnsExist(db, 'entries', const <String>[
        'account_id',
        'amount',
      ])) {
        await db.execute('''
          UPDATE entries SET account_amount =
            CASE WHEN account_id <> '' THEN amount ELSE NULL END
        ''');
      }
      if (await _columnsExist(db, 'entries', const <String>[
        'to_account_id',
        'amount',
      ])) {
        await db.execute('''
          UPDATE entries SET to_account_amount = CASE
            WHEN to_account_id IS NOT NULL AND to_account_id <> '' THEN amount
            ELSE NULL
          END
        ''');
      }
      if (await _columnsExist(db, 'entries', const <String>[
        'type',
        'amount',
      ])) {
        await db.execute('''
          UPDATE entries SET base_amount =
            CASE WHEN type = 'transfer' THEN 0 ELSE amount END
        ''');
      }
    }
    if (await _tableExists(db, 'recurring_rules')) {
      await db.execute(
        "ALTER TABLE recurring_rules ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
      await db.execute(
        'ALTER TABLE recurring_rules ADD COLUMN account_amount REAL',
      );
      await db.execute(
        'ALTER TABLE recurring_rules ADD COLUMN to_account_amount REAL',
      );
      await db.execute(
        'ALTER TABLE recurring_rules ADD COLUMN base_amount REAL NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE recurring_rules ADD COLUMN rate_policy TEXT NOT NULL DEFAULT 'fixedAmounts'",
      );
      await db.execute('''
        UPDATE recurring_rules
        SET account_amount = CASE WHEN account_id <> '' THEN amount ELSE NULL END,
            to_account_amount = CASE
              WHEN to_account_id IS NOT NULL AND to_account_id <> '' THEN amount
              ELSE NULL
            END,
            base_amount = CASE WHEN type = 'transfer' THEN 0 ELSE amount END
      ''');
    }
    await db.execute(_exchangeRatesTable);
    await db.execute(_exchangeRatesLookupIndex);
  }

  /// v14 → v15：账户分组回归纯文件夹语义，移除可自定义图标字段。
  /// 分组 id、名称、账本归属和排序全部原样保留；账户的 group_id 无需改写。
  static Future<void> _migrateToV15(Database db) async {
    if (!await _tableExists(db, 'account_groups')) {
      return;
    }
    await db.execute('DROP INDEX IF EXISTS idx_account_groups_book');
    await db.execute('ALTER TABLE account_groups RENAME TO account_groups_v14');
    await db.execute(_accountGroupsTableCurrent);
    await db.execute('''
      INSERT INTO account_groups (id, book_id, name, sort_order)
      SELECT id, book_id, name, sort_order FROM account_groups_v14
    ''');
    await db.execute('DROP TABLE account_groups_v14');
    await db.execute(_accountGroupsBookIndex);
  }

  /// v15 → v16：账户图标统一进入 SVG 目录。三个旧 code 只在此处
  /// 做一次性转换，后续渲染层不再保留历史兼容分支。
  static Future<void> _migrateToV16(Database db) async {
    if (!await _tableExists(db, 'accounts')) {
      return;
    }
    await db.execute('''
      UPDATE accounts SET icon_code = CASE icon_code
        WHEN 'alipay' THEN 'asset:payment_006'
        WHEN 'wechat' THEN 'asset:payment_004'
        WHEN 'folder' THEN 'wallet'
        ELSE icon_code
      END
      WHERE icon_code IN ('alipay', 'wechat', 'folder')
    ''');
  }

  /// v16 → v17：预算外支出。交易新增「不计入预算」标记，默认 0（照常计入预算）。
  static Future<void> _migrateToV17(Database db) async {
    if (!await _tableExists(db, 'entries')) {
      return;
    }
    // 全新库的 onCreate 已带该列，迁移矩阵里「库结构比 user_version 新」的库也是；
    // 直接 ALTER 会因重复列名失败。
    if (await _columnsExist(db, 'entries', const <String>[
      'excluded_from_budget',
    ])) {
      return;
    }
    await db.execute(
      'ALTER TABLE entries ADD COLUMN excluded_from_budget INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// v17 → v18：附件文件化。附件字节改为应用私有目录下的独立文件，SQLite 只保存
  /// 元数据（`mime_type` / `byte_size`）。历史行的 `data_url` 保留为可空列，供启动后的
  /// 后台转换任务逐条解成文件后清空；转换完成前读取路径是「文件优先、`data_url` 兜底」，
  /// 因此迁移可中断、可重试，且不会丢数据。
  ///
  /// 表结构变更走「建新表 → 拷贝 → 改名」而非 `ALTER ... DROP COLUMN`：既要加列，
  /// 又要把 `data_url` 从 NOT NULL 放宽为可空，重建是唯一对所有 SQLite 版本都安全的路径。
  static Future<void> _migrateToV18(Database db) async {
    if (!await _tableExists(db, 'attachments')) {
      return;
    }
    if (await _columnsExist(db, 'attachments', const <String>[
      'mime_type',
      'byte_size',
    ])) {
      return;
    }
    await db.execute('''
      CREATE TABLE attachments_v18 (
        id TEXT PRIMARY KEY,
        entry_id TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        mime_type TEXT NOT NULL DEFAULT 'image/jpeg',
        byte_size INTEGER NOT NULL DEFAULT 0,
        data_url TEXT
      )
    ''');
    await db.execute('''
      INSERT INTO attachments_v18
        (id, entry_id, sort_order, mime_type, byte_size, data_url)
      SELECT id, entry_id, sort_order, 'image/jpeg', 0, data_url
      FROM attachments
    ''');
    await db.execute('DROP TABLE attachments');
    await db.execute('ALTER TABLE attachments_v18 RENAME TO attachments');
    // DROP TABLE 会一并删除旧索引，这里重建。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_attachments_entry ON attachments (entry_id)',
    );
  }

  /// v18 → v19：分类与标签改为**账本内数据**。
  ///
  /// 旧结构里 `categories` / `tags` 是全局的（没有 `book_id`），所有账本共用一张表，
  /// 于是出现了「A 账本删不掉被 B 账本用过的分类」「改名/换图标/排序全账本生效」
  /// 「删标签会静默改写别的账本交易」这些问题。本段把每条分类/标签复制到**每个**
  /// 账本——旧模型下每个账本看到的本来就是同一张表，全量复制能让升级前后用户可见的
  /// 分类/标签集合完全一致——并把交易、周期规则与分类预算里的引用改写到该账本自己的
  /// 副本上（每条副本由 [_nextMigrationId] 重新生成随机 id，整库唯一，因此
  /// `categoryById(id)` 不需要账本上下文）。
  ///
  /// 无法归属的引用（悬空分类、已折叠的重复标签、账本已不存在的交易）就地清理：
  /// 分类悬空引用由 controller 载入时的自愈归入该账本「未分类」，标签直接摘掉。
  static Future<void> _migrateToV19(Database db) async {
    // 表结构与索引无论如何都要升到 v19 形态（全新库也只有一种结构），数据归属才是
    // 条件性的：没有账本信息时（最小桩库）把所有旧记录归到默认账本，与
    // `_bookScopedBudgets` 对无账本前缀旧键的回落口径一致。
    final bookIds = await _tableExists(db, 'ledger_books')
        ? ((await db.query(
            'ledger_books',
            columns: const <String>['id'],
          )).map((row) => row['id'] as String).toList()..sort())
        : const <String>[];
    final scope = bookIds.isEmpty
        ? const <String>[defaultLedgerBookId]
        : bookIds;
    if (await _tableExists(db, 'categories')) {
      await _scopeCategoriesToBooks(db, scope);
    }
    if (await _tableExists(db, 'tags')) {
      await _scopeTagsToBooks(db, scope);
    }
  }

  /// 把全局分类复制到每个账本，并把交易/周期规则/分类预算的引用指向副本。
  static Future<void> _scopeCategoriesToBooks(
    Database db,
    List<String> bookIds,
  ) async {
    if (await _columnsExist(db, 'categories', const <String>[
      'book_id',
      'category_key',
    ])) {
      return; // 结构已比 user_version 新（迁移矩阵会构造这种库）
    }
    final rows = await db.query('categories', orderBy: 'sort_order ASC');
    await _alterCategoriesToScoped(db);
    // 旧唯一索引不含 book_id，不先删就没法给第二个账本插入同名分类。
    await db.execute('DROP INDEX IF EXISTS idx_categories_unique');
    await db.execute('DELETE FROM categories');
    // 分类 id 一律随机生成、不承载语义：每个账本各拿一份**全新 id** 的副本，
    // 旧 id 若是有约定的语义键（默认分类/余额调整/未分类）就转成 `category_key`。
    final newIdsByBook = <String, Map<String, String>>{
      for (final bookId in bookIds)
        bookId: <String, String>{
          for (final row in rows)
            row['id'] as String: _nextMigrationId('category'),
        },
    };
    for (final bookId in bookIds) {
      final ids = newIdsByBook[bookId]!;
      for (final row in rows) {
        final oldId = row['id'] as String;
        final rawParent = row['parent_id'] as String?;
        final parent = (rawParent == null || rawParent.isEmpty)
            ? null
            : rawParent;
        await db.insert('categories', <String, Object?>{
          'id': ids[oldId],
          'book_id': bookId,
          'label': row['label'],
          'type': row['type'],
          'icon_code': row['icon_code'],
          'sort_order': row['sort_order'],
          'parent_id': parent == null ? null : ids[parent],
          'category_key': isKnownCategoryKey(oldId) ? oldId : null,
        });
      }
    }
    // 引用改写用临时映射表 + 相关子查询，一条 SQL 覆盖所有账本（空分类保持空串、
    // 映射不到的悬空引用原样保留，交给 controller 载入时的自愈处理）。
    // 判列存在只为兼容最小桩库：没有 book_id 时无法判定归属，保持原 id。
    await db.execute(
      'CREATE TEMP TABLE _category_scope_map ('
      'book_id TEXT NOT NULL, old_id TEXT NOT NULL, new_id TEXT NOT NULL)',
    );
    final mapping = db.batch();
    for (final entry in newIdsByBook.entries) {
      for (final pair in entry.value.entries) {
        mapping.insert('_category_scope_map', <String, Object?>{
          'book_id': entry.key,
          'old_id': pair.key,
          'new_id': pair.value,
        });
      }
    }
    await mapping.commit(noResult: true);
    if (await _tableExists(db, 'entries') &&
        await _columnsExist(db, 'entries', const <String>['book_id'])) {
      await db.execute(
        'UPDATE entries SET category_id = ('
        'SELECT new_id FROM _category_scope_map m '
        'WHERE m.book_id = entries.book_id AND m.old_id = entries.category_id'
        ') WHERE category_id <> \'\' AND EXISTS ('
        'SELECT 1 FROM _category_scope_map m '
        'WHERE m.book_id = entries.book_id AND m.old_id = entries.category_id'
        ')',
      );
    }
    if (await _tableExists(db, 'recurring_rules') &&
        await _columnsExist(db, 'recurring_rules', const <String>['book_id'])) {
      await db.execute(
        'UPDATE recurring_rules SET category_id = ('
        'SELECT new_id FROM _category_scope_map m '
        'WHERE m.book_id = recurring_rules.book_id '
        'AND m.old_id = recurring_rules.category_id'
        ') WHERE category_id <> \'\' AND EXISTS ('
        'SELECT 1 FROM _category_scope_map m '
        'WHERE m.book_id = recurring_rules.book_id '
        'AND m.old_id = recurring_rules.category_id'
        ')',
      );
    }
    await db.execute('DROP TABLE _category_scope_map');
    await _scopeCategoryBudgetKeys(db, newIdsByBook);
    await db.execute(_categoriesScopedUniqueIndex);
    await db.execute(_categoriesBookIndex);
    await db.execute(_categoriesKeyIndex);
  }

  /// 分类预算键 `<bookId>:<yyyy-MM|default>:<categoryId>` 的尾部换成账本内 id。
  /// 只有能明确解析成「已知账本 + 月份段 + 分类」的键才改写；更早版本的无账本前缀
  /// 键（`yyyy-MM:<categoryId>`）按 `_bookScopedBudgets` 的口径归默认账本；其余
  /// 无法解析的键原样保留（它们本来也不会被任何月份查询命中）。
  static Future<void> _scopeCategoryBudgetKeys(
    Database db,
    Map<String, Map<String, String>> newIdsByBook,
  ) async {
    if (!await _tableExists(db, 'category_budgets')) {
      return;
    }
    final legacyMonth = RegExp(r'^\d{4}-\d{2}$');
    final rows = await db.query(
      'category_budgets',
      columns: const <String>['scope_key'],
    );
    for (final row in rows) {
      final oldKey = row['scope_key'] as String;
      final parts = oldKey.split(':');
      String? bookId;
      String? monthSegment;
      String? oldCategoryId;
      if (parts.length == 3 && newIdsByBook.containsKey(parts[0])) {
        bookId = parts[0];
        monthSegment = parts[1];
        oldCategoryId = parts[2];
      } else if (parts.length == 2 && legacyMonth.hasMatch(parts[0])) {
        // 更早的键没有账本前缀（`yyyy-MM:<categoryId>`）。
        bookId = defaultLedgerBookId;
        monthSegment = parts[0];
        oldCategoryId = parts[1];
      } else {
        continue;
      }
      final newCategoryId = newIdsByBook[bookId]?[oldCategoryId];
      if (newCategoryId == null) {
        continue; // 指向未知分类：键保持原样（本来也不会被月份查询命中）
      }
      final newKey = '$bookId:$monthSegment:$newCategoryId';
      if (newKey == oldKey) {
        continue;
      }
      await db.update(
        'category_budgets',
        <String, Object?>{'scope_key': newKey},
        where: 'scope_key = ?',
        whereArgs: <Object?>[oldKey],
      );
    }
  }

  /// 把全局标签复制到每个账本，并重写交易的 `tag_ids`。
  static Future<void> _scopeTagsToBooks(
    Database db,
    List<String> bookIds,
  ) async {
    if (await _columnsExist(db, 'tags', const <String>['book_id'])) {
      return;
    }
    if (!await _columnsExist(db, 'tags', const <String>[
      'id',
      'label',
      'sort_order',
    ])) {
      return; // 桩库结构不完整
    }
    final rows = await db.query('tags', orderBy: 'sort_order ASC');
    await _alterTagsToScoped(db);
    await db.execute('DELETE FROM tags');
    // 旧表没有唯一约束，同一账本内的同名标签只保留第一条（与 controller 的
    // 「按名称复用」口径一致）；被折叠掉的旧 id 在重写交易引用时指向保留者。
    // 每份副本都拿**新生成的随机 id**。
    final rowByOldId = <String, Map<String, Object?>>{
      for (final row in rows) row['id'] as String: row,
    };
    final labelByOldId = <String, String>{
      for (final row in rows) row['id'] as String: row['label'] as String,
    };
    final keeperIdByLabel = <String, String>{};
    for (final row in rows) {
      keeperIdByLabel.putIfAbsent(
        row['label'] as String,
        () => row['id'] as String,
      );
    }
    final tagIdsByBook = <String, Map<String, String>>{};
    for (final bookId in bookIds) {
      final newIdByKeeperId = <String, String>{};
      for (final row in rows) {
        newIdByKeeperId.putIfAbsent(
          keeperIdByLabel[row['label'] as String]!,
          () => _nextMigrationId('tag'),
        );
      }
      for (final entry in newIdByKeeperId.entries) {
        await db.insert('tags', <String, Object?>{
          'id': entry.value,
          'book_id': bookId,
          'label': labelByOldId[entry.key],
          'sort_order': rowByOldId[entry.key]!['sort_order'],
        });
      }
      tagIdsByBook[bookId] = <String, String>{
        for (final row in rows)
          row['id'] as String:
              newIdByKeeperId[keeperIdByLabel[row['label'] as String]!]!,
      };
    }
    await _rewriteEntryTagIds(db, tagIdsByBook);
    await db.execute(_tagsBookIndex);
    await db.execute(_tagsUniqueIndex);
  }

  /// 重写每笔交易 `tag_ids` 里的标签引用：旧 id → 该交易所属账本的副本 id。
  /// `tag_ids` 是 JSON 数组，没法用一条 SQL 完成，只能逐行处理（只碰有标签的行）。
  static Future<void> _rewriteEntryTagIds(
    Database db,
    Map<String, Map<String, String>> tagIdsByBook,
  ) async {
    if (!await _tableExists(db, 'entries')) {
      return;
    }
    if (!await _columnsExist(db, 'entries', const <String>[
      'id',
      'book_id',
      'tag_ids',
    ])) {
      return;
    }
    final rows = await db.query(
      'entries',
      columns: const <String>['id', 'book_id', 'tag_ids'],
      where: "tag_ids IS NOT NULL AND tag_ids <> '' AND tag_ids <> '[]'",
    );
    for (final row in rows) {
      final entryId = row['id'] as String;
      final bookId = row['book_id'] as String;
      final ids = tagIdsByBook[bookId];
      final mapped = <String>[];
      if (ids != null) {
        for (final value in _decodeTagIdList(row['tag_ids'] as String)) {
          final newId = ids[value.toString()];
          if (newId == null) {
            continue; // 悬空引用：指向的标签不存在
          }
          if (!mapped.contains(newId)) {
            mapped.add(newId);
          }
        }
      }
      await db.update(
        'entries',
        <String, Object?>{'tag_ids': jsonEncode(mapped)},
        where: 'id = ?',
        whereArgs: <Object?>[entryId],
      );
    }
  }

  /// 解析 `tag_ids` 的 JSON 数组；坏数据按「没有标签」处理（与模型层的
  /// `_stringList` 口径一致）。
  static List<Object?> _decodeTagIdList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : const <Object?>[];
    } on FormatException {
      return const <Object?>[];
    }
  }

  static Future<void> _alterCategoriesToScoped(Database db) async {
    if (!await _columnsExist(db, 'categories', const <String>['book_id'])) {
      await db.execute(
        "ALTER TABLE categories ADD COLUMN book_id TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!await _columnsExist(db, 'categories', const <String>[
      'category_key',
    ])) {
      await db.execute('ALTER TABLE categories ADD COLUMN category_key TEXT');
    }
  }

  static Future<void> _alterTagsToScoped(Database db) async {
    if (await _columnsExist(db, 'tags', const <String>['book_id'])) {
      return;
    }
    await db.execute(
      "ALTER TABLE tags ADD COLUMN book_id TEXT NOT NULL DEFAULT ''",
    );
  }

  /// 迁移期生成实体 id：形态与 controller 的 `_generateId` 一致（微秒时间戳 +
  /// 单调序号），保证 id 随机、唯一、不承载语义。
  static String _nextMigrationId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_migrationIdSeq++}';

  static int _migrationIdSeq = 0;

  static Future<bool> _tableExists(Database db, String name) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      <Object?>[name],
    );
    return rows.isNotEmpty;
  }

  static Future<bool> _columnsExist(
    Database db,
    String table,
    List<String> names,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    final existing = rows.map((row) => row['name']).whereType<String>().toSet();
    return names.every(existing.contains);
  }

  /// 合并重复分类：保留每个 (label,type,IFNULL(parent_id,'')) 组内 rowid 最小的一条，
  /// 其余的交易/周期规则/子分类 parent_id 引用改指向保留者后删除。仅在对应表存在时改写引用
  /// （真实库都在，判存在是为兼容最小桩库）。
  static Future<void> _dedupeCategories(Database db) async {
    await db.execute('''
      CREATE TEMP TABLE _cat_keep AS
        SELECT id AS keep_id, label, type, IFNULL(parent_id, '') AS pkey
        FROM categories
        WHERE rowid IN (
          SELECT MIN(rowid) FROM categories
          GROUP BY label, type, IFNULL(parent_id, '')
        )
    ''');
    await db.execute('''
      CREATE TEMP TABLE _cat_map AS
        SELECT c.id AS old_id, k.keep_id AS keep_id
        FROM categories c
        JOIN _cat_keep k
          ON c.label = k.label AND c.type = k.type
          AND IFNULL(c.parent_id, '') = k.pkey
    ''');
    if (await _tableExists(db, 'entries')) {
      await db.execute('''
        UPDATE entries
          SET category_id =
            (SELECT keep_id FROM _cat_map WHERE old_id = entries.category_id)
          WHERE category_id IN
            (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
      ''');
    }
    if (await _tableExists(db, 'recurring_rules')) {
      await db.execute('''
        UPDATE recurring_rules
          SET category_id =
            (SELECT keep_id FROM _cat_map WHERE old_id = recurring_rules.category_id)
          WHERE category_id IN
            (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
      ''');
    }
    await db.execute('''
      UPDATE categories
        SET parent_id =
          (SELECT keep_id FROM _cat_map WHERE old_id = categories.parent_id)
        WHERE parent_id IN (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
    ''');
    await db.execute('''
      DELETE FROM categories
        WHERE id IN (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
    ''');
    await db.execute('DROP TABLE _cat_map');
    await db.execute('DROP TABLE _cat_keep');
  }

  /// v10 起的分类唯一约束：同一父级（顶级按空串归一）下不允许同 label+type 的
  /// 重复分类。**这是历史定义，只被 v10 迁移段使用**（那时的表还没有 book_id）；
  /// v19 会先 DROP 这个索引再建下面的账本作用域版本，两者同名。
  static const String _categoriesUniqueIndex =
      "CREATE UNIQUE INDEX idx_categories_unique "
      "ON categories (label, type, IFNULL(parent_id, ''))";

  /// v19 起的分类唯一约束：**同一账本内**、同一父级下不允许重复分类。
  static const String _categoriesScopedUniqueIndex =
      "CREATE UNIQUE INDEX idx_categories_unique "
      "ON categories (book_id, label, type, IFNULL(parent_id, ''))";

  static const String _categoriesBookIndex =
      'CREATE INDEX idx_categories_book ON categories (book_id)';

  /// 同一账本内的语义键唯一（用户自建分类的键为 NULL，SQLite 的唯一索引把 NULL 视为
  /// 互不相同，因此不限制数量）。
  static const String _categoriesKeyIndex =
      'CREATE UNIQUE INDEX idx_categories_key ON categories '
      '(book_id, category_key)';

  /// v19 起的标签唯一约束：同一账本内不允许同名标签（旧表没有唯一约束，
  /// v19 迁移会先按 label 折叠重复项再建索引）。
  static const String _tagsUniqueIndex =
      'CREATE UNIQUE INDEX idx_tags_unique ON tags (book_id, label)';

  static const String _tagsBookIndex =
      'CREATE INDEX idx_tags_book ON tags (book_id)';

  static const String _dailyBudgetsTable = '''
    CREATE TABLE daily_budgets (
      scope_key TEXT PRIMARY KEY,
      amount REAL NOT NULL
    )
  ''';

  /// v7 历史建表语句冻结副本。后续字段只能在新迁移段追加。
  static const String _recurringRulesTableV7 = '''
    CREATE TABLE recurring_rules (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      category_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      to_account_id TEXT,
      note TEXT NOT NULL,
      frequency TEXT NOT NULL,
      start_date INTEGER NOT NULL,
      next_run_date INTEGER NOT NULL,
      active INTEGER NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''';

  static const String _recurringRulesTableCurrent = '''
    CREATE TABLE recurring_rules (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      currency_code TEXT NOT NULL DEFAULT 'CNY',
      account_amount REAL,
      to_account_amount REAL,
      base_amount REAL NOT NULL DEFAULT 0,
      rate_policy TEXT NOT NULL DEFAULT 'fixedAmounts',
      category_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      to_account_id TEXT,
      note TEXT NOT NULL,
      frequency TEXT NOT NULL,
      start_date INTEGER NOT NULL,
      next_run_date INTEGER NOT NULL,
      active INTEGER NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''';

  static const String _exchangeRatesTable = '''
    CREATE TABLE exchange_rates (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      base_currency_code TEXT NOT NULL,
      currency_code TEXT NOT NULL,
      effective_date TEXT NOT NULL,
      rate_to_base REAL NOT NULL,
      source TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE (book_id, base_currency_code, currency_code, effective_date)
    )
  ''';

  static const String _exchangeRatesLookupIndex =
      'CREATE INDEX idx_exchange_rates_book_currency_date '
      'ON exchange_rates (book_id, currency_code, effective_date)';

  static const String _accountGroupsTableCurrent = '''
    CREATE TABLE account_groups (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''';

  static const String _accountGroupsBookIndex =
      'CREATE INDEX idx_account_groups_book ON account_groups (book_id)';

  /// 当前完整建表语句（供全新数据库 onCreate 用）。字段命名用 snake_case；
  /// 布尔存 0/1；时间存毫秒时间戳。已含历次迁移引入的列/表（parent_id、tags 等）。
  static const List<String> _schemaCurrent = <String>[
    '''
    CREATE TABLE ledger_books (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      is_default INTEGER NOT NULL,
      base_currency_code TEXT NOT NULL DEFAULT 'CNY',
      currency_setup_status TEXT NOT NULL DEFAULT 'legacyUnconfirmed',
      sort_order INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE entries (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      currency_code TEXT NOT NULL DEFAULT 'CNY',
      account_amount REAL,
      to_account_amount REAL,
      base_amount REAL NOT NULL DEFAULT 0,
      conversion_source TEXT NOT NULL DEFAULT 'legacy',
      category_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      to_account_id TEXT,
      note TEXT NOT NULL,
      occurred_at INTEGER NOT NULL,
      tag_ids TEXT,
      fee REAL NOT NULL DEFAULT 0,
      reimbursable INTEGER NOT NULL DEFAULT 0,
      excluded_from_budget INTEGER NOT NULL DEFAULT 0,
      refunded_amount REAL NOT NULL DEFAULT 0,
      refund_of TEXT,
      settled_at INTEGER
    )
    ''',
    'CREATE INDEX idx_entries_book ON entries (book_id)',
    'CREATE INDEX idx_entries_occurred ON entries (occurred_at)',
    '''
    CREATE TABLE accounts (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      group_id TEXT,
      initial_balance REAL NOT NULL,
      currency_code TEXT NOT NULL DEFAULT 'CNY',
      icon_code TEXT NOT NULL,
      note TEXT NOT NULL,
      include_in_assets INTEGER NOT NULL,
      hidden INTEGER NOT NULL,
      card_last4 TEXT NOT NULL,
      card_number TEXT NOT NULL DEFAULT '',
      card_last4_follows INTEGER NOT NULL DEFAULT 1,
      credit_limit REAL,
      sort_order INTEGER NOT NULL,
      statement_day INTEGER,
      due_day INTEGER,
      asset_class TEXT NOT NULL DEFAULT 'other',
      base_valuation REAL
    )
    ''',
    'CREATE INDEX idx_accounts_book ON accounts (book_id)',
    _assetSnapshotsTable,
    _accountGroupsTableCurrent,
    _accountGroupsBookIndex,
    '''
    CREATE TABLE categories (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      label TEXT NOT NULL,
      type TEXT NOT NULL,
      icon_code TEXT NOT NULL,
      sort_order INTEGER NOT NULL,
      parent_id TEXT,
      category_key TEXT
    )
    ''',
    _categoriesBookIndex,
    _categoriesScopedUniqueIndex,
    _categoriesKeyIndex,
    '''
    CREATE TABLE monthly_budgets (
      scope_key TEXT PRIMARY KEY,
      amount REAL NOT NULL
    )
    ''',
    '''
    CREATE TABLE category_budgets (
      scope_key TEXT PRIMARY KEY,
      amount REAL NOT NULL
    )
    ''',
    _dailyBudgetsTable,
    '''
    CREATE TABLE tags (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      label TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    )
    ''',
    _tagsBookIndex,
    _tagsUniqueIndex,
    '''
    CREATE TABLE attachments (
      id TEXT PRIMARY KEY,
      entry_id TEXT NOT NULL,
      sort_order INTEGER NOT NULL,
      mime_type TEXT NOT NULL DEFAULT 'image/jpeg',
      byte_size INTEGER NOT NULL DEFAULT 0,
      data_url TEXT
    )
    ''',
    'CREATE INDEX idx_attachments_entry ON attachments (entry_id)',
    _recurringRulesTableCurrent,
    _exchangeRatesTable,
    _exchangeRatesLookupIndex,
  ];
}
