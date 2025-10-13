import { createHash, randomUUID, randomBytes } from 'node:crypto'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

function hash (value) {
  const hash = createHash('sha256')
  hash.update(value)
  return hash.digest('hex')
}

export function response () {
  const filepath = join(tmpdir(), randomUUID())

  const buffer = randomBytes(1024 * 10)
  writeFileSync(filepath, buffer)
  const checksum = hash(buffer)

  return { value: buffer.toString('hex'), filepath, checksum }
}
