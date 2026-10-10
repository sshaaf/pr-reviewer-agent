import { NextRequest } from "next/server"
import { db } from "@/lib/db"
import { encrypt } from "@/lib/crypto"
import { withAdmin, ok, err } from "@/lib/api"

export const GET = withAdmin(async (_req, user) => {
  const apps = await db.app.findMany({
    select: { id: true, name: true, provider: true, appId: true, createdAt: true, createdBy: true },
    orderBy: { createdAt: "desc" },
  })
  return ok(apps)
})

export const POST = withAdmin(async (req, user) => {
  const { name, provider, appId, privateKey, webhookSecret } = await req.json().catch(() => ({}))
  if (!name || !provider || !appId || !privateKey || !webhookSecret) {
    return err("name, provider, appId, privateKey, webhookSecret required", 400)
  }
  const existing = await db.app.findUnique({ where: { name } })
  if (existing) return err("App already exists", 409)

  const app = await db.app.create({
    data: {
      name, provider, appId,
      privateKeyEnc: encrypt(privateKey),
      webhookSecretEnc: encrypt(webhookSecret),
      createdBy: user.id,
    },
    select: { id: true, name: true, provider: true, appId: true, createdAt: true },
  })
  return ok(app, 201)
})
