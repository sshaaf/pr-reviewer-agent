import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"
import { deleteAgentResources } from "@/lib/k8s"

export const GET = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
    include: { config: true },
  })
  return repo ? ok(repo) : err("Not found", 404)
})

export const DELETE = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
  })
  if (!repo) return err("Not found", 404)

  await deleteAgentResources(repo).catch(e => console.error("[repos] deleteAgentResources failed:", e))
  await db.repo.delete({ where: { id: repo.id } })
  return ok({ deleted: true })
})
