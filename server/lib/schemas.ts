import { z } from "zod";

/**
 * Swift `AppContext` shape, shared by every route that accepts it
 * (`POST /api/compose`, `POST /api/intent`, and now `POST /api/transcribe`'s
 * P1.2 `localTranscript` fields) — kept in one place so they can't drift.
 */
export const appContextSchema = z
  .object({
    bundleID: z.string().nullable().optional(),
    appName: z.string().nullable().optional(),
    windowTitle: z.string().nullable().optional(),
    url: z.string().nullable().optional(),
  })
  .nullable()
  .optional();

export type AppContextInput = z.infer<typeof appContextSchema>;
