"use client"
import { useEffect, useState } from "react"

type User = { id: string; email: string; role: string; createdAt: string }

export default function UsersAdminPage() {
  const [users, setUsers] = useState<User[]>([])
  const [email, setEmail] = useState("")
  const [role, setRole] = useState("user")
  const [msg, setMsg] = useState("")

  const load = () => fetch("/api/v1/users").then(r => r.json()).then(setUsers)
  useEffect(() => { load() }, [])

  async function createUser(e: React.FormEvent) {
    e.preventDefault()
    const res = await fetch("/api/v1/users", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, role }),
    })
    if (res.ok) {
      const data = await res.json()
      setMsg(data.temporaryPassword ? `User created. Temporary password: ${data.temporaryPassword}` : "User created.")
      setEmail("")
      load()
    } else {
      const d = await res.json()
      setMsg(d.error ?? "Error")
    }
    setTimeout(() => setMsg(""), 10000)
  }

  async function deleteUser(id: string) {
    if (!confirm("Delete user?")) return
    await fetch(`/api/v1/users/${id}`, { method: "DELETE" })
    load()
  }

  return (
    <div className="p-8 max-w-3xl mx-auto space-y-8">
      <h1 className="text-2xl font-bold">Users</h1>

      <form onSubmit={createUser} className="flex gap-3 items-end">
        <div className="flex-1">
          <label className="block text-sm font-medium mb-1">Email</label>
          <input type="email" value={email} onChange={e => setEmail(e.target.value)}
            className="w-full border rounded px-3 py-2 text-sm" required />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Role</label>
          <select value={role} onChange={e => setRole(e.target.value)} className="border rounded px-3 py-2 text-sm">
            <option value="user">User</option>
            <option value="admin">Admin</option>
          </select>
        </div>
        <button type="submit" className="bg-blue-600 text-white px-4 py-2 rounded text-sm font-medium hover:bg-blue-700">
          Create
        </button>
      </form>
      {msg && <p className="text-sm bg-gray-50 border rounded p-3 font-mono">{msg}</p>}

      <table className="w-full text-sm border rounded overflow-hidden">
        <thead className="bg-gray-50">
          <tr>
            <th className="px-3 py-2 text-left">Email</th>
            <th className="px-3 py-2 text-left">Role</th>
            <th className="px-3 py-2 text-left">Created</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {users.map(u => (
            <tr key={u.id} className="border-t">
              <td className="px-3 py-2">{u.email}</td>
              <td className="px-3 py-2">{u.role}</td>
              <td className="px-3 py-2">{new Date(u.createdAt).toLocaleDateString()}</td>
              <td className="px-3 py-2">
                <button onClick={() => deleteUser(u.id)} className="text-red-600 text-xs hover:underline">Delete</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
