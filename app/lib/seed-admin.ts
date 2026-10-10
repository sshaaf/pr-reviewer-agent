import bcrypt from "bcryptjs"
import { db } from "./db"

export async function seedAdmin() {
  const email = process.env.ADMIN_EMAIL
  const password = process.env.ADMIN_PASSWORD
  if (!email || !password) return

  const exists = await db.user.findFirst({ where: { role: "admin" } })
  if (exists) return

  await db.user.create({
    data: {
      email,
      passwordHash: await bcrypt.hash(password, 12),
      role: "admin",
    },
  })
  console.log(`[seed] Admin user created: ${email}`)
}
