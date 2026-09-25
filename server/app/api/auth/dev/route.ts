import { z } from "zod";
import { signSessionToken } from "@/lib/auth";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { getStore } from "@/lib/store";

export const dynamic = "force-dynamic";

const bodySchema = z.object({
  email: z.string().email(),
});

export const POST = withErrorHandling(async (req: Request) => {
  if (process.env.PROSIO_DEV_AUTH !== "1") {
    // Per docs/API.md: "Only when PROSIO_DEV_AUTH=1, else 404."
    return Response.json({ error: { code: "not_found", message: "Not found" } }, { status: 404 });
  }

  const json = await req.json().catch(() => null);
  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) {
    throw new ApiError("bad_request", "Body must be { email: string }");
  }

  const store = getStore();
  const user = await store.findOrCreateUser(parsed.data.email);
  const sessionToken = await signSessionToken(user);

  return Response.json({ sessionToken, user });
});
