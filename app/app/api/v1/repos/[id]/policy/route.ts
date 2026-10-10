import { NextRequest } from "next/server"
import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"

export const GET = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
    include: { policy: true },
  })
  return repo ? ok(repo.policy) : err("Not found", 404)
})

export const PUT = withAuth(async (req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
  })
  if (!repo) return err("Not found", 404)

  const body = await req.text()
  try { JSON.parse(body) } catch { return err("Invalid JSON", 400) }

  const policy = await db.repoPolicy.upsert({
    where: { repoId: repo.id },
    create: { repoId: repo.id, policyJson: body },
    update: { policyJson: body },
  })
  return ok(policy)
})
