import { NextRequest } from "next/server"
import { db } from "@/lib/db"
import { encrypt } from "@/lib/crypto"
import { withAdmin, ok, err } from "@/lib/api"

export const GET = withAdmin(async (_req, _user, params) => {
  const app = await db.app.findUnique({
    where: { id: params?.id },
    select: { id: true, name: true, provider: true, appId: true, createdAt: true, createdBy: true },
  })
  return app ? ok(app) : err("Not found", 404)
})

export const PUT = withAdmin(async (req, _user, params) => {
  const { privateKey, webhookSecret } = await req.json().catch(() => ({}))
  const updated = await db.app.update({
    where: { id: params?.id },
    data: {
      ...(privateKey ? { privateKeyEnc: encrypt(privateKey) } : {}),
      ...(webhookSecret ? { webhookSecretEnc: encrypt(webhookSecret) } : {}),
    },
    select: { id: true, name: true, provider: true, appId: true },
  })
  return ok(updated)
})

export const DELETE = withAdmin(async (_req, _user, params) => {
  await db.app.delete({ where: { id: params?.id } })
  return ok({ deleted: true })
})
