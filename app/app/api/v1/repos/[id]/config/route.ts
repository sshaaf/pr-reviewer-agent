import { NextRequest } from "next/server"
import { db } from "@/lib/db"
import { withAuth, ok, err } from "@/lib/api"
import { scopeFilter } from "@/lib/auth"

export const GET = withAuth(async (_req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
    include: { config: true },
  })
  return repo ? ok(repo.config) : err("Not found", 404)
})

export const PUT = withAuth(async (req, user, params) => {
  const repo = await db.repo.findFirst({
    where: { id: params?.id, ...scopeFilter(user) as object },
  })
  if (!repo) return err("Not found", 404)

  const { checks, upstream_depth, downstream_depth, fanout, output_mode } = await req.json().catch(() => ({}))
  const config = await db.repoConfig.upsert({
    where: { repoId: repo.id },
    create: {
      repoId: repo.id,
      ...(checks ? { checks } : {}),
      ...(upstream_depth != null ? { upstreamDepth: upstream_depth } : {}),
      ...(downstream_depth != null ? { downstreamDepth: downstream_depth } : {}),
      ...(fanout != null ? { fanout } : {}),
      ...(output_mode ? { outputMode: output_mode } : {}),
    },
    update: {
      ...(checks ? { checks } : {}),
      ...(upstream_depth != null ? { upstreamDepth: upstream_depth } : {}),
      ...(downstream_depth != null ? { downstreamDepth: downstream_depth } : {}),
      ...(fanout != null ? { fanout } : {}),
      ...(output_mode ? { outputMode: output_mode } : {}),
    },
  })
  return ok(config)
})
