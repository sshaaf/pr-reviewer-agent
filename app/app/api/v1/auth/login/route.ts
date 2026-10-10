import { NextRequest, NextResponse } from "next/server"
import bcrypt from "bcryptjs"
import { db } from "@/lib/db"
import { createSessionToken, sessionCookieHeader } from "@/lib/auth"
import { err } from "@/lib/api"

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({}))
  const { email, password } = body
  if (!email || !password) return err("email and password required", 400)

  const user = await db.user.findUnique({ where: { email } })
  if (!user || !(await bcrypt.compare(password, user.passwordHash))) {
    return err("Invalid credentials", 401)
  }

  const token = await createSessionToken(user.id)
  const res = NextResponse.json({ id: user.id, email: user.email, role: user.role })
  res.headers.set("Set-Cookie", sessionCookieHeader(token))
  return res
}
