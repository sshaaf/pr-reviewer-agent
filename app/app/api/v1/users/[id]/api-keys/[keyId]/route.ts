import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"

export const DELETE = withAuth(async (_req, user, params) => {
  const { id, keyId } = params ?? {}
  if (user.role !== "admin" && user.id !== id) return err("Not found", 404)
  const key = await db.apiKey.findFirst({ where: { id: keyId, userId: id } })
  if (!key) return err("Not found", 404)
  await db.apiKey.delete({ where: { id: keyId } })
  return ok({ deleted: true })
})
