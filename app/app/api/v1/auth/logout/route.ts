import { NextResponse } from "next/server"
import { clearSessionCookieHeader } from "@/lib/auth"

export async function DELETE() {
  const res = NextResponse.json({ ok: true })
  res.headers.set("Set-Cookie", clearSessionCookieHeader())
  return res
}
