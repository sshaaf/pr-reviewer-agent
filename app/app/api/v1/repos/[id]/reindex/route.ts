import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"
import { createDiscoverJob } from "@/lib/k8s"

export const POST = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
  })
  if (!repo) return err("Not found", 404)

  const jobName = await createDiscoverJob(repo)
  await db.repo.update({
    where: { id: repo.id },
    data: { status: "indexing", discoverJobName: jobName, indexError: null },
  })
  return ok({ status: "indexing", discoverJobName: jobName })
})
