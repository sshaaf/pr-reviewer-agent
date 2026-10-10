import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"

export const GET = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
  })
  if (!repo) return err("Not found", 404)

  const review = await db.review.findFirst({
    where: { repoId: repo.id, prNumber: Number(params?.prNumber) },
  })
  return review ? ok(review) : err("Not found", 404)
})
