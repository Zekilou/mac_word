import GRDB

/// v0 建表迁移：nodes 登记薄 + edges 登记薄 + 15 张 comp_* 组件表 + 索引。
/// 所有 comp_* 表以 entity_id 为 PK + FK → nodes(id) ON DELETE CASCADE。
/// v1：用户词汇掌握度（全局上下文）+ 多来源释义 + text_a 索引（10 万词级性能）。
/// v2：掌握度值域迁移（旧 0~1 → 新 1~2，0=无记录/1=不会/2=会）。
/// v3：`comp_user_known.seen_count`（出现过次数）。
/// v4：`comp_region` / `comp_word_event` / `comp_lemma_frequency`。
/// v5：`comp_mastery_belief`（BKT 后验概率）。
/// v6：旧数据事件回填（mastery / seen_count → 词事件，让 BKT 后验对历史数据有值）。
/// v7：清洗存量脏文本（Anki HTML / [sound:] / 实体残留）。
enum SchemaMigrator {
    static func migrate(_ writer: some DatabaseWriter) throws {
        var m = DatabaseMigrator()
        m.registerMigration("v0_initial") { db in
            try createAllTables(db)
            try createAllIndexes(db)
            try createTriggers(db)
        }
        m.registerMigration("v1_user_known") { db in
            try db.execute(sql: """
                CREATE TABLE comp_user_known (
                    entity_id  TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    mastery    REAL NOT NULL,
                    source     TEXT NOT NULL,
                    updated_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE comp_lemma_definitions (
                    entity_id        TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    definitions_json TEXT
                )
                """)
            // 词形精确/前缀查询索引（COLLATE NOCASE 使 findLemmaId 可走索引，10 万词级）
            try db.execute(sql: "CREATE INDEX idx_comp_text_text_a ON comp_text(text_a COLLATE NOCASE)")
        }
        // 掌握度值域：旧 0=不会/1=会 → 新 0=无记录/1=不会/2=会（线性 +1，0.5 → 1.5 保持中间语义）。
        // @ai: 只对旧值域数据执行一次；新库空表无操作。
        m.registerMigration("v2_user_known_scale") { db in
            try db.execute(sql: """
                UPDATE comp_user_known
                SET mastery = mastery + 1
                WHERE mastery >= 0 AND mastery <= 1
                """)
        }
        // v3：出现记录（seen）——RSS 等文章中的词自动记"出现过"，但不判定会/不会。
        // mastery 语义不变（0=无记录/1=不会/2=会）；seen_count>0 且 mastery<=0 = 出现过未确认。
        m.registerMigration("v3_user_known_seen") { db in
            try db.execute(sql: """
                ALTER TABLE comp_user_known
                ADD COLUMN seen_count INTEGER NOT NULL DEFAULT 0
                """)
        }
        // v4：词汇显示上下文（region）+ 全量词事件流 + 词频族坐标。
        m.registerMigration("v4_region_and_word_event") { db in
            try db.execute(sql: """
                CREATE TABLE comp_region (
                    entity_id  TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    kind       TEXT NOT NULL,
                    label      TEXT,
                    source_id  TEXT,
                    trust      REAL NOT NULL,
                    created_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE comp_word_event (
                    entity_id   TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    lemma_id    TEXT NOT NULL,
                    region_id   TEXT NOT NULL,
                    event_kind  TEXT NOT NULL,
                    trust       REAL NOT NULL,
                    occurred_at DATETIME NOT NULL,
                    detail_json TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE comp_lemma_frequency (
                    entity_id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    band      INTEGER NOT NULL,
                    freq_rank INTEGER NOT NULL,
                    source    TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_word_event_lemma_time ON comp_word_event(lemma_id, occurred_at)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_word_event_region ON comp_word_event(region_id)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_region_source ON comp_region(source_id)
                """)
        }
        // v5：BKT 后验掌握度概率。
        m.registerMigration("v5_mastery_belief") { db in
            try db.execute(sql: """
                CREATE TABLE comp_mastery_belief (
                    entity_id      TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    belief         REAL NOT NULL,
                    opportunities  INTEGER NOT NULL,
                    last_event_at  DATETIME,
                    updated_at     DATETIME NOT NULL,
                    params_version TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_mastery_belief_belief ON comp_mastery_belief(belief)
                """)
        }
        // v6：旧数据事件回填——把 v4 之前产生的 mastery / seen_count 合成为词事件流，
        // 让 BKT 后验对历史数据也有值（事件挂专用 legacy region，可按 region 回滚）。
        // @ai: 只写事件；后验由启动时 VocabularyMaintenance.backfillMastery 重算。
        m.registerMigration("v6_legacy_event_backfill") { db in
            try LegacyEventBackfill.run(db)
        }
        // v7：清洗存量脏文本。
        // @ai: 背景——`AnkiImporter+Sanitize` 是 v1.0.0（d506dde）才加的，而用户库里的
        //      TOEFL 词库导入于 2026-08-10（更早），headword 落库成
        //      `abandon<div>[sound:abandon_400.mp3]</div><div>[ə'bændən]</div>`。
        //      后果不只是「首页显示尖括号」：LemmaFrequencySystem 直接用 text_a 查词频表，
        //      脏词面一个都查不到（实测 402 个词只有 1 个命中）→ 词频/CEFR/选词分层全部失效。
        //      这里就地清洗 storage 层，让下游所有查询（含词频回填）重新拿到干净词面。
        //      幂等：clean 只会收紧文本，重复执行结果不变。
        m.registerMigration("v7_sanitize_stored_text") { db in
            try StoredTextSanitizer.run(db)
        }
        // v8：剥掉词面里的音标 / 词性尾巴（`abandon [ə'bændən]` → `abandon`）。
        // @ai: v7 只去了 HTML，音标尾巴还在，词频表依然查不到（实测 402 词仍只 1 命中）。
        //      词面是 Lemma 的匹配键，必须只留纯词形；音标归 comp_lemma_meta.phonetic_*。
        m.registerMigration("v8_strip_headword_tail") { db in
            try StoredTextSanitizer.stripHeadwordTails(db)
        }
        // v9：斜杠音标尾巴（`rotate /rou'teit/` → `rotate`）。
        // @ai: v8 只处理了方括号音标；另一批词库用斜杠写法，仍留在词面里。
        m.registerMigration("v9_strip_slash_phonetic") { db in
            try StoredTextSanitizer.stripHeadwordTails(db)
        }
        try m.migrate(writer)
    }

    // MARK: - Tables

    private static func createAllTables(_ db: Database) throws {
        // 登记薄
        try db.execute(sql: """
            CREATE TABLE nodes (
                id         TEXT PRIMARY KEY,
                kind       TEXT NOT NULL,
                created_at DATETIME NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE edges (
                id         TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                src_id     TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                dst_id     TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                rel_type   TEXT NOT NULL,
                created_at DATETIME NOT NULL
            )
            """)

        // 组件表 — 每张表 entity_id 为 PK + FK
        try db.execute(sql: """
            CREATE TABLE comp_text (
                entity_id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                text_a    TEXT,
                text_b    TEXT,
                language  TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_lemma_meta (
                entity_id    TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                pos          TEXT,
                phonetic_us  TEXT,
                phonetic_uk  TEXT,
                senses_json  TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_deck_meta (
                entity_id   TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                name        TEXT,
                source_kind TEXT,
                source_path TEXT,
                imported_at DATETIME
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_schedule_state (
                entity_id        TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                stability        REAL,
                difficulty       REAL,
                due_at           DATETIME,
                interval_days    REAL,
                reps             INTEGER,
                lapses           INTEGER,
                last_rating      INTEGER,
                last_reviewed_at DATETIME,
                scheduler_id     TEXT,
                queue            TEXT,
                custom_data_json TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_review_event (
                entity_id        TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                target_card_id   TEXT,
                rated_at         DATETIME,
                rating           INTEGER,
                responded_ms     INTEGER,
                elapsed_days     REAL,
                scheduled_interval REAL,
                delta_stability  REAL,
                delta_difficulty REAL,
                last_ivl         REAL,
                factor           REAL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_media_refs (
                entity_id   TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                entries_json TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_generation_meta (
                entity_id    TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                mode         TEXT,
                topic        TEXT,
                source_text  TEXT,
                generator_id TEXT,
                quality_tier TEXT,
                prompt_hash  TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_edge_span (
                entity_id   TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                surface_form TEXT,
                start       INTEGER,
                end         INTEGER,
                is_target   INTEGER
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_edge_weighted (
                entity_id      TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                weight_double  REAL,
                source_type    TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_edge_position (
                entity_id           TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                position_in_sentence INTEGER,
                surface_form        TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_tag_set (
                entity_id  TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                tags_json  TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_order (
                entity_id  TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                sort_index INTEGER
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_custom_data (
                entity_id    TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                payload_json TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_import_failure (
                entity_id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                deck_id   TEXT,
                row_index INTEGER,
                raw_line  TEXT,
                reason    TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE comp_analytics_cache (
                entity_id    TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                module_id    TEXT,
                scope_hash   TEXT,
                computed_at  DATETIME,
                payload_json TEXT
            )
            """)
    }

    // MARK: - Indexes

    private static func createAllIndexes(_ db: Database) throws {
        try db.execute(sql: "CREATE INDEX idx_nodes_kind ON nodes(kind)")
        try db.execute(sql: "CREATE INDEX idx_edges_src_rel ON edges(src_id, rel_type)")
        try db.execute(sql: "CREATE INDEX idx_edges_dst_rel ON edges(dst_id, rel_type)")
        try db.execute(sql: "CREATE INDEX idx_schedule_due ON comp_schedule_state(due_at, scheduler_id)")
        try db.execute(sql: "CREATE INDEX idx_review_target_time ON comp_review_event(target_card_id, rated_at)")
        try db.execute(sql: "CREATE INDEX idx_gen_mode ON comp_generation_meta(mode)")
        try db.execute(sql: "CREATE INDEX idx_cache_lookup ON comp_analytics_cache(module_id, scope_hash)")
    }

    // MARK: - Triggers

    /// edges 行被删除时（含 CASCADE），自动清理对应的 nodes 行。
    /// 因为 edges.id → nodes.id 的 CASCADE 只在 nodes 被删时触发，不反向。
    private static func createTriggers(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER trg_edges_delete_node
            AFTER DELETE ON edges
            FOR EACH ROW
            BEGIN
                DELETE FROM nodes WHERE id = OLD.id;
            END
            """)
    }
}
