import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"

export const GET = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
  })
  if (!repo) return err("Not found", 404)

  const reviews = await db.review.findMany({
    where: { repoId: repo.id },
    orderBy: { createdAt: "desc" },
  })
  return ok(reviews)
})
