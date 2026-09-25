// Vitest setup: sane defaults for every test file. Individual tests can
// still override process.env per-case (e.g. to exercise PROSIO_DEV_AUTH=0).
process.env.PROSIO_JWT_SECRET = process.env.PROSIO_JWT_SECRET ?? "test-secret-do-not-use-in-prod";
process.env.PROSIO_DEV_AUTH = process.env.PROSIO_DEV_AUTH ?? "1";
delete process.env.DATABASE_URL; // always exercise MemoryStore in tests
delete process.env.AI_GATEWAY_API_KEY; // gateway calls are mocked per-test where needed
