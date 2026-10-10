import crypto from "crypto"

const KEY = Buffer.from(process.env.ENCRYPTION_KEY ?? "00000000000000000000000000000000", "hex")
const IV_LEN = 16

export function encrypt(plain: string): string {
  const iv = crypto.randomBytes(IV_LEN)
  const cipher = crypto.createCipheriv("aes-256-cbc", KEY, iv)
  const enc = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()])
  return iv.toString("hex") + ":" + enc.toString("hex")
}

export function decrypt(enc: string): string {
  const [ivHex, dataHex] = enc.split(":")
  const iv = Buffer.from(ivHex, "hex")
  const decipher = crypto.createDecipheriv("aes-256-cbc", KEY, iv)
  return Buffer.concat([decipher.update(Buffer.from(dataHex, "hex")), decipher.final()]).toString("utf8")
}
