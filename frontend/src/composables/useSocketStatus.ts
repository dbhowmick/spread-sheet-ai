import { onScopeDispose, readonly, ref, type Ref } from 'vue'

import { currentConnectionState, onConnectionChange, type ConnectionState } from '@/lib/socket'

/**
 * Reactive view of the Phoenix socket's connection state. Vue reactivity is
 * kept out of `src/lib/socket.ts`, which stays framework-agnostic.
 */
export function useSocketStatus(): Readonly<Ref<ConnectionState>> {
  const status = ref<ConnectionState>(currentConnectionState())
  const stop = onConnectionChange((next) => {
    status.value = next
  })
  onScopeDispose(stop)
  return readonly(status)
}
