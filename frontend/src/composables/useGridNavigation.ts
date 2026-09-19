/**
 * The active cell, keyboard handling and clipboard for one grid
 * (frontend-plan §7.4).
 *
 * Every *decision* lives in `lib/sheet/navigation.ts` and `lib/sheet/paste.ts`
 * as a pure function. This composable owns only what can't be pure: the refs,
 * DOM focus, scrolling, `ClipboardEvent`s and sending ops.
 *
 * **Focus lives on the scroll container, not on cells.** A roving `tabindex`
 * cannot work here: the virtualizer unmounts rows that scroll away, so the
 * focused element would vanish and focus would silently fall to `<body>`,
 * leaving the grid unresponsive with nothing on screen to explain it. The
 * container is never unmounted, so `document.activeElement` stays put — which
 * also makes it the reliable target for `copy` and `paste`.
 */
import { computed, shallowRef, watch, type ComputedRef, type Ref, type ShallowRef } from 'vue'
import type { Virtualizer } from '@tanstack/vue-virtual'
import { toast } from 'vue-sonner'

import type { SheetNavContext } from '@/components/sheet/context'
import {
  EMPTY_NAV_GRID,
  NO_ACTIVE,
  cellDomId,
  gridIntent,
  move,
  navGrid,
  posOf,
  reconcileActive,
  reconcileEditing,
  scrollLeftFor,
  setActive,
  type ActiveCell,
  type CellRef,
  type EditingState,
  type Move,
  type NavGrid,
} from '@/lib/sheet/navigation'
import { planPaste, skippedMessage } from '@/lib/sheet/paste'
import { cellKey, cellOf } from '@/lib/sheet/state'
import { formatValue, parseInput, validateLabel } from '@/lib/sheet/values'
import type { CellValue, Column, ColumnId, Op, SetCellsOp } from '@/types/contract'
import type { SheetState } from '@/lib/sheet/state'

export interface UseGridNavigationOptions {
  view: Ref<SheetState | null>
  /** Sheet column ids in render order, gutter excluded. */
  navColumnIds: Ref<ColumnId[]>
  scrollElement: Ref<HTMLElement | null>
  /**
   * Read lazily: the virtualizer's `rangeExtractor` needs `activeRowIndex`
   * from here, so the two would otherwise be a definition cycle.
   */
  virtualizer: () => Virtualizer<HTMLElement, Element> | null
  /** Total width of the pinned start columns, which overlay the scroll. */
  frozenWidth: Ref<number>
  /** A column's horizontal offset and width, for scrolling it into view. */
  columnRect: (columnId: ColumnId) => { start: number; size: number } | null
  apply: (op: Op) => Promise<void>
  /** Prefix for `cellDomId`, so two grids on one page don't collide. */
  gridId: string
}

export interface UseGridNavigation {
  nav: SheetNavContext
  active: Readonly<ShallowRef<ActiveCell>>
  activeDescendantId: ComputedRef<string | undefined>
  /** The active row's index, to pin it into the virtual range. */
  activeRowIndex: ComputedRef<number | null>
  onKeydown: (event: KeyboardEvent) => void
  onCopy: (event: ClipboardEvent) => void
  onPaste: (event: ClipboardEvent) => void
  focusGrid: () => void
}

export function useGridNavigation(options: UseGridNavigationOptions): UseGridNavigation {
  const { view, navColumnIds, scrollElement, virtualizer, apply, gridId } = options

  const active = shallowRef<ActiveCell>(NO_ACTIVE)
  const editing = shallowRef<EditingState | null>(null)

  const grid = computed<NavGrid>(() => {
    const state = view.value
    if (!state) return EMPTY_NAV_GRID
    return navGrid(
      state.rows.map((row) => row.id),
      navColumnIds.value,
    )
  })

  // Absorb remote structure changes: keep the ids when they still resolve, and
  // fall back to the remembered index when the row or column has gone.
  watch(grid, (next) => {
    active.value = reconcileActive(active.value, next)
    editing.value = reconcileEditing(editing.value, next)
  })

  const activeKey = computed(() =>
    active.value.cell ? cellKey(active.value.cell.rowId, active.value.cell.columnId) : null,
  )

  const activeColumn = computed<Column | null>(() => {
    const cell = active.value.cell
    if (!cell || !view.value) return null
    return view.value.columnsById[cell.columnId] ?? null
  })

  const activeRowIndex = computed(() => {
    const cell = active.value.cell
    if (!cell) return null
    return posOf(grid.value, cell)?.row ?? null
  })

  const activeDescendantId = computed(() => {
    const cell = active.value.cell
    return cell ? cellDomId(gridId, cell.rowId, cell.columnId) : undefined
  })

  function focusGrid(): void {
    // `preventScroll`: a plain focus() on a scroll container jumps scrollTop.
    scrollElement.value?.focus({ preventScroll: true })
  }

  function scrollIntoView(cell: CellRef): void {
    const at = posOf(grid.value, cell)
    if (!at) return
    virtualizer()?.scrollToIndex(at.row, { align: 'auto' })

    // Columns are not virtualized, so the horizontal axis is ours to do.
    const element = scrollElement.value
    const rect = options.columnRect(cell.columnId)
    if (!element || !rect) return
    const left = scrollLeftFor({
      scrollLeft: element.scrollLeft,
      viewport: element.clientWidth,
      frozen: options.frozenWidth.value,
      start: rect.start,
      size: rect.size,
    })
    if (left !== null) element.scrollLeft = left
  }

  function activate(cell: CellRef): void {
    active.value = setActive(grid.value, cell)
    editing.value = null
    scrollIntoView(cell)
  }

  function moveActive(m: Move): void {
    const next = move(grid.value, active.value.cell, m)
    if (next) activate(next)
  }

  function beginEdit(cell: CellRef, initialInput: string | null = null): void {
    const column = view.value?.columnsById[cell.columnId]
    // Booleans toggle in place; there is nothing to open.
    if (!column || column.column_type === 'boolean') return
    active.value = setActive(grid.value, cell)
    editing.value = { cell, initialInput, error: null }
    scrollIntoView(cell)
  }

  function cancel(): void {
    editing.value = null
    focusGrid()
  }

  function setCell(cell: CellRef, value: CellValue): void {
    const op: SetCellsOp = {
      type: 'set_cells',
      // The `value` key must be explicit: omitting it is `invalid_op`, and
      // `null` is what clears a cell (contract §6).
      cells: [{ row_id: cell.rowId, column_id: cell.columnId, value }],
    }
    void apply(op)
  }

  /**
   * Parses raw text for its column and sends it. Both the editors and paste
   * come through here, so the rules live in one place — which is why editors
   * emit their raw string rather than a parsed value.
   */
  function commit(input: string, next: Move | null): void {
    const current = editing.value
    const state = view.value
    if (!current || !state) return

    const column = state.columnsById[current.cell.columnId]
    if (!column) return

    if (column.is_label) {
      const checked = validateLabel(input, state, current.cell.rowId)
      if (!checked.ok) {
        editing.value = { ...current, error: checked.message }
        return
      }
      editing.value = null
      setCell(current.cell, checked.value)
    } else {
      const parsed = parseInput(column.column_type, input)
      if (!parsed.ok) {
        editing.value = { ...current, error: parsed.message }
        return
      }
      editing.value = null
      setCell(current.cell, parsed.value)
    }

    focusGrid()
    if (next) moveActive(next)
  }

  function toggleBoolean(cell: CellRef): void {
    const state = view.value
    const column = state?.columnsById[cell.columnId]
    if (!state || !column || column.column_type !== 'boolean') return

    const row = state.rows[state.rowIndexById[cell.rowId] ?? -1]
    if (!row) return

    active.value = setActive(grid.value, cell)
    // An empty boolean cell reads as "not yet true", so the first click sets it.
    setCell(cell, cellOf(row, cell.columnId) !== true)
    focusGrid()
  }

  function clearActive(): void {
    const cell = active.value.cell
    if (cell) setCell(cell, null)
  }

  function onKeydown(event: KeyboardEvent): void {
    // The editor owns every key while it is open. It also stops propagation
    // itself, but the `DateEditor`'s popover teleports out of this subtree, so
    // this guard is the one that always holds.
    if (editing.value) return

    const column = activeColumn.value
    const intent = gridIntent(event, {
      hasActive: active.value.cell !== null,
      columnType: column?.column_type ?? null,
      isLabelColumn: column?.is_label ?? false,
    })

    switch (intent.kind) {
      case 'native':
      case 'ignore':
        // Never preventDefault Ctrl+C/V/X: that would suppress the browser's
        // own clipboard events, which is how copy and paste work here.
        return

      case 'move':
        event.preventDefault()
        moveActive(intent.move)
        return

      case 'edit':
        event.preventDefault()
        if (active.value.cell) beginEdit(active.value.cell, intent.initialInput)
        return

      case 'toggle':
        event.preventDefault()
        if (active.value.cell) toggleBoolean(active.value.cell)
        return

      case 'clear':
        event.preventDefault()
        clearActive()
        return

      case 'refuse':
        event.preventDefault()
        toast.warning(intent.reason)
        return
    }
  }

  function onCopy(event: ClipboardEvent): void {
    const cell = active.value.cell
    const state = view.value
    if (!cell || !state || editing.value) return

    const column = state.columnsById[cell.columnId]
    const row = state.rows[state.rowIndexById[cell.rowId] ?? -1]
    if (!column || !row) return

    event.preventDefault()
    // No locale: the clipboard has to round-trip back through `parseInput`,
    // and a localized number would not.
    event.clipboardData?.setData(
      'text/plain',
      formatValue(column.column_type, cellOf(row, cell.columnId)),
    )
  }

  function onPaste(event: ClipboardEvent): void {
    const cell = active.value.cell
    const state = view.value
    if (!cell || !state || editing.value) return

    const text = event.clipboardData?.getData('text/plain') ?? ''
    if (text === '') return
    event.preventDefault()

    const plan = planPaste(text, grid.value, cell, state)
    for (const op of plan.ops) void apply(op)

    const skipped = skippedMessage(plan)
    if (skipped) toast.warning(skipped)
  }

  const nav: SheetNavContext = {
    activeKey,
    editing,
    activate,
    beginEdit,
    commit,
    cancel,
    toggleBoolean,
  }

  return {
    nav,
    active,
    activeDescendantId,
    activeRowIndex,
    onKeydown,
    onCopy,
    onPaste,
    focusGrid,
  }
}
