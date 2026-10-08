import { doublePrecision, pgTable, text, timestamp, uniqueIndex, uuid } from "drizzle-orm/pg-core";

export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  email: text("email").notNull().unique(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const usageEvents = pgTable(
  "usage_events",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    // Server-accounted dictation session; idempotency is scoped to the user.
    sessionId: uuid("session_id").notNull(),
    engineId: text("engine_id").notNull(),
    audioSeconds: doublePrecision("audio_seconds").notNull(),
    startedAt: timestamp("started_at", { withTimezone: true }).notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [uniqueIndex("usage_events_user_session_key").on(table.userId, table.sessionId)]
);

export const dictionaryEntries = pgTable(
  "dictionary_entries",
  {
    // Client-generated entry id (matches Swift DictionaryEntry.id).
    id: uuid("id").notNull(),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    term: text("term").notNull(),
    note: text("note"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
  },
  (table) => [uniqueIndex("dictionary_entries_user_id_id_key").on(table.userId, table.id)]
);
