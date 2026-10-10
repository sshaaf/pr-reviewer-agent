import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"

export const GET = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
    select: { status: true, lastIndexedAt: true, indexError: true },
  })
  return repo ? ok(repo) : err("Not found", 404)
})
