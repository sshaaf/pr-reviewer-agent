import { NextRequest } from "next/server"
import bcrypt from "bcryptjs"
import { db } from "@/lib/db"
import { withAuth, withAdmin, ok, err } from "@/lib/api"

export const GET = withAdmin(async (_req, _user) => {
  const users = await db.user.findMany({
    select: { id: true, email: true, role: true, createdAt: true },
    orderBy: { createdAt: "desc" },
  })
  return ok(users)
})

export const POST = withAdmin(async (req) => {
  const { email, role, password } = await req.json().catch(() => ({}))
  if (!email) return err("email required", 400)

  const existing = await db.user.findUnique({ where: { email } })
  if (existing) return err("User already exists", 409)

  const rawPassword = password ?? Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2)
  const user = await db.user.create({
    data: { email, role: role ?? "user", passwordHash: await bcrypt.hash(rawPassword, 12) },
    select: { id: true, email: true, role: true, createdAt: true },
  })
  return ok({ ...user, temporaryPassword: password ? undefined : rawPassword }, 201)
})
