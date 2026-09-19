import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { SheetTransport, SheetTransportHandlers } from '@/lib/transport/types'
import type { Sheet } from '@/types/contract'

const sheet: Sheet = {
  id: 's1',
  name: 'Budget',
  owner: { id: 'u1', display_name: 'Alice' },
  version: 1,
  columns: [{ id: 'c-label', name: 'Line item', column_type: 'text', is_label: true }],
  rows: [{ id: 'r1', cells: { 'c-label': 'Revenue' } }],
  inserted_at: '2026-09-19T10:00:00Z',
  updated_at: '2026-09-19T10:00:00Z',
}

const join = vi.fn()
const leave = vi.fn()
let lastHandlers: SheetTransportHandlers | null = null

vi.mock('@/lib/transport', () => ({
  createSheetTransport: (_sheetId: string, handlers: SheetTransportHandlers): SheetTransport => {
    lastHandlers = handlers
    return {
      join,
      leave,
      pushOp: vi.fn(),
      snapshot: vi.fn(),
    }
  },
}))

const { useSheetsStore } = await import('@/stores/sheets')

describe('joining a sheet', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    lastHandlers = null
    join.mockReset()
    leave.mockReset()
  })

  it('holds the sheet ready once the join reply arrives', async () => {
    join.mockResolvedValue({ ok: true, data: { sheet } })
    const store = useSheetsStore()

    await store.open('s1')

    expect(store.statusOf('s1').value).toBe('ready')
    expect(store.viewOf('s1').value?.name).toBe('Budget')
    expect(store.errorOf('s1').value).toBeNull()
    expect(lastHandlers).not.toBeNull()
  })

  it('keeps a failed join visible as an error instead of joining forever', async () => {
    join.mockResolvedValue({ ok: false, error: { code: 'not_found', message: 'no such sheet' } })
    const store = useSheetsStore()

    await store.open('missing')

    expect(store.statusOf('missing').value).toBe('error')
    expect(store.errorOf('missing').value?.code).toBe('not_found')
    expect(leave).toHaveBeenCalledOnce()
  })

  it('leaves only when the last holder releases the sheet (§6.4)', async () => {
    join.mockResolvedValue({ ok: true, data: { sheet } })
    const store = useSheetsStore()

    await store.open('s1')
    await store.open('s1')

    store.close('s1')
    expect(leave).not.toHaveBeenCalled()
    expect(store.statusOf('s1').value).toBe('ready')

    store.close('s1')
    expect(leave).toHaveBeenCalledOnce()
    expect(store.viewOf('s1').value).toBeNull()
  })
})
