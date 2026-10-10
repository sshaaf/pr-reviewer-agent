import { NextRequest } from "next/server"
import crypto from "crypto"
import { db } from "@/lib/db"
import { hashApiKey } from "@/lib/auth"
import { withAuth, ok, err } from "@/lib/api"

export const POST = withAuth(async (req, user, params) => {
  const targetId = params?.id
  if (user.role !== "admin" && user.id !== targetId) return err("Not found", 404)

  const { name } = await req.json().catch(() => ({}))
  if (!name) return err("name required", 400)

  const secret = `lwk_live_${crypto.randomBytes(24).toString("hex")}`
  const key = await db.apiKey.create({
    data: { userId: targetId!, name, keyHash: await hashApiKey(secret) },
    select: { id: true, name: true, createdAt: true },
  })
  return ok({ ...key, secret }, 201)
})
