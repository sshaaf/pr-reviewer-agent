import { NextRequest } from "next/server"
import { SignJWT, jwtVerify } from "jose"
import bcrypt from "bcryptjs"
import { db } from "./db"
import { User } from "@prisma/client"

const SESSION_SECRET = new TextEncoder().encode(
  process.env.SESSION_SECRET ?? "change-me-in-production-32-chars!!"
)
const SESSION_COOKIE = "pr_reviewer_session"

// ── Session (UI) ─────────────────────────────────────────────────────────────

export async function createSessionToken(userId: string): Promise<string> {
  return new SignJWT({ sub: userId })
    .setProtectedHeader({ alg: "HS256" })
    .setExpirationTime("8h")
    .sign(SESSION_SECRET)
}

export async function verifySessionToken(token: string): Promise<string | null> {
  try {
    const { payload } = await jwtVerify(token, SESSION_SECRET)
    return payload.sub ?? null
  } catch {
    return null
  }
}

// ── API key (bot) ────────────────────────────────────────────────────────────

export async function hashApiKey(secret: string): Promise<string> {
  return bcrypt.hash(secret, 10)
}

async function lookupApiKey(secret: string): Promise<User | null> {
  const keys = await db.apiKey.findMany({ include: { user: true } })
  for (const k of keys) {
    if (await bcrypt.compare(secret, k.keyHash)) {
      await db.apiKey.update({ where: { id: k.id }, data: { lastUsedAt: new Date() } })
      return k.user
    }
  }
  return null
}

// ── Shared middleware resolver ───────────────────────────────────────────────

export async function resolveUser(req: NextRequest): Promise<User | null> {
  // 1. Bearer token (bot)
  const auth = req.headers.get("authorization") ?? ""
  if (auth.startsWith("Bearer ")) {
    return lookupApiKey(auth.slice(7))
  }

  // 2. Session cookie (UI)
  const cookie = req.cookies.get(SESSION_COOKIE)?.value
  if (cookie) {
    const userId = await verifySessionToken(cookie)
    if (userId) {
      return db.user.findUnique({ where: { id: userId } })
    }
  }

  return null
}

export function scopeFilter(user: User): object {
  if (user.role === "admin") return {}
  return { ownerId: user.id }
}

export function sessionCookieHeader(token: string): string {
  return `${SESSION_COOKIE}=${token}; HttpOnly; Path=/; SameSite=Lax; Max-Age=28800`
}

export function clearSessionCookieHeader(): string {
  return `${SESSION_COOKIE}=; HttpOnly; Path=/; Max-Age=0`
}

export { SESSION_COOKIE }
