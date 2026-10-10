import { NextRequest, NextResponse } from "next/server"
import { User } from "@prisma/client"
import { resolveUser } from "./auth"

type Handler = (req: NextRequest, user: User, params?: Record<string, string>) => Promise<NextResponse>

export function withAuth(handler: Handler) {
  return async (req: NextRequest, context?: { params?: Record<string, string> }) => {
    const user = await resolveUser(req)
    if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 })
    return handler(req, user, context?.params)
  }
}

export function withAdmin(handler: Handler) {
  return withAuth(async (req, user, params) => {
    if (user.role !== "admin") return NextResponse.json({ error: "Forbidden" }, { status: 403 })
    return handler(req, user, params)
  })
}

export function ok(data: unknown, status = 200) {
  return NextResponse.json(data, { status })
}

export function err(message: string, status: number) {
  return NextResponse.json({ error: message }, { status })
}
