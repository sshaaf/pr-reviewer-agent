import { withAuth, ok } from "@/lib/api"

export const GET = withAuth(async (_req, user) => {
  return ok({ id: user.id, email: user.email, role: user.role })
})
