import { NextRequest } from "next/server"
import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"

type Ctx = { params: { id: string } }

export const GET = withAuth(async (_req, user, params) => {
  const id = params?.id
  if (user.role !== "admin" && user.id !== id) return err("Not found", 404)
  const found = await db.user.findUnique({
    where: { id },
    select: { id: true, email: true, role: true, createdAt: true },
  })
  return found ? ok(found) : err("Not found", 404)
})

export const PUT = withAuth(async (req, user, params) => {
  const id = params?.id
  if (user.role !== "admin" && user.id !== id) return err("Not found", 404)
  const { email } = await req.json().catch(() => ({}))
  const updated = await db.user.update({
    where: { id },
    data: { ...(email ? { email } : {}) },
    select: { id: true, email: true, role: true },
  })
  return ok(updated)
})

export const DELETE = withAuth(async (_req, user, params) => {
  const id = params?.id
  if (user.role !== "admin") return err("Forbidden", 403)
  await db.user.delete({ where: { id } })
  return ok({ deleted: true })
})
