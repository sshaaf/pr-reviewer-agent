"use client"
import { useEffect, useState } from "react"

type ApiKey = { id: string; name: string; createdAt: string; lastUsedAt: string | null }

export default function ApiKeysPage() {
  const [keys, setKeys] = useState<ApiKey[]>([])
  const [userId, setUserId] = useState("")
  const [name, setName] = useState("")
  const [newSecret, setNewSecret] = useState("")

  useEffect(() => {
    fetch("/api/v1/auth/me").then(r => r.json()).then(u => {
      setUserId(u.id)
      fetch(`/api/v1/users/${u.id}/api-keys`).then(r => r.json()).then(setKeys)
    })
  }, [])

  async function createKey(e: React.FormEvent) {
    e.preventDefault()
    const res = await fetch(`/api/v1/users/${userId}/api-keys`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    })
    if (res.ok) {
      const data = await res.json()
      setNewSecret(data.secret)
      setName("")
      fetch(`/api/v1/users/${userId}/api-keys`).then(r => r.json()).then(setKeys)
    }
  }

  async function revokeKey(keyId: string) {
    if (!confirm("Revoke this key?")) return
    await fetch(`/api/v1/users/${userId}/api-keys/${keyId}`, { method: "DELETE" })
    setKeys(prev => prev.filter(k => k.id !== keyId))
  }

  return (
    <div className="p-8 max-w-2xl mx-auto space-y-8">
      <h1 className="text-2xl font-bold">API Keys</h1>

      <form onSubmit={createKey} className="flex gap-3 items-end">
        <div className="flex-1">
          <label className="block text-sm font-medium mb-1">Key name</label>
          <input value={name} onChange={e => setName(e.target.value)} placeholder="e.g. ci-bot"
            className="w-full border rounded px-3 py-2 text-sm" required />
        </div>
        <button type="submit" className="bg-blue-600 text-white px-4 py-2 rounded text-sm font-medium hover:bg-blue-700">
          Generate
        </button>
      </form>

      {newSecret && (
        <div className="bg-yellow-50 border border-yellow-300 rounded p-4">
          <p className="text-sm font-medium text-yellow-800 mb-1">Copy this secret — it will not be shown again.</p>
          <code className="block font-mono text-sm break-all">{newSecret}</code>
        </div>
      )}

      <table className="w-full text-sm border rounded overflow-hidden">
        <thead className="bg-gray-50">
          <tr>
            <th className="px-3 py-2 text-left">Name</th>
            <th className="px-3 py-2 text-left">Created</th>
            <th className="px-3 py-2 text-left">Last used</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {keys.map(k => (
            <tr key={k.id} className="border-t">
              <td className="px-3 py-2">{k.name}</td>
              <td className="px-3 py-2">{new Date(k.createdAt).toLocaleDateString()}</td>
              <td className="px-3 py-2">{k.lastUsedAt ? new Date(k.lastUsedAt).toLocaleDateString() : "Never"}</td>
              <td className="px-3 py-2">
                <button onClick={() => revokeKey(k.id)} className="text-red-600 text-xs hover:underline">Revoke</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
