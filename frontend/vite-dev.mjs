/**
 * Vite dev server wrapper for Phoenix integration.
 *
 * Phoenix watchers communicate via stdin pipe. When Phoenix shuts down,
 * stdin receives EOF. This wrapper detects that and gracefully stops Vite,
 * preventing orphaned node processes from holding the port.
 */
import { createServer } from 'vite'

const server = await createServer()
await server.listen()
server.printUrls()

process.stdin.resume()
process.stdin.on('end', async () => {
  await server.close()
  process.exit()
})
