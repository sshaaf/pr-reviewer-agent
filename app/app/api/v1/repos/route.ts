import { NextRequest } from "next/server"
import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"
import { createAgentResources, createDiscoverJob } from "@/lib/k8s"

export const GET = withAuth(async (_req, user) => {
  const repos = await db.repo.findMany({
    where: scopeFilter(user) as object,
    include: { config: true },
    orderBy: { createdAt: "desc" },
  })
  return ok(repos)
})

export const POST = withAuth(async (req, user) => {
  const { appId, repoUrl, config } = await req.json().catch(() => ({}))
  if (!appId || !repoUrl) return err("appId and repoUrl required", 400)

  const app = await db.app.findUnique({ where: { id: appId } })
  if (!app) return err("App not found", 404)

  const existing = await db.repo.findFirst({ where: { ownerId: user.id, repoUrl } })
  if (existing) return err("Repo already registered", 409)

  const repo = await db.repo.create({
    data: {
      ownerId: user.id,
      appId,
      repoUrl,
      status: "indexing",
      config: config ? {
        create: {
          checks: config.checks ?? ["paths", "blast_radius", "policy"],
          upstreamDepth: config.upstream_depth ?? 2,
          downstreamDepth: config.downstream_depth ?? 1,
          fanout: config.fanout ?? 10,
          outputMode: config.output_mode ?? "comment",
        }
      } : { create: {} },
    },
    include: { config: true },
  })

  // Create per-repo opencode Deployment + Service + PVC, then enqueue DiscoverJob
  const { deploymentName, serviceUrl } = await createAgentResources(repo).catch(e => {
    console.error("[repos] createAgentResources failed:", e)
    return { deploymentName: null, serviceUrl: null }
  })

  const jobName = await createDiscoverJob(repo).catch(e => {
    console.error("[repos] createDiscoverJob failed:", e)
    return null
  })

  await db.repo.update({
    where: { id: repo.id },
    data: {
      ...(deploymentName ? { opencodeDeploymentName: deploymentName } : {}),
      ...(serviceUrl ? { opencodeServiceUrl: serviceUrl } : {}),
      ...(jobName ? { discoverJobName: jobName } : {}),
    },
  })

  return ok(repo, 201)
})
