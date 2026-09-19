/**
 * The TanStack table behind `SheetGrid` (frontend-plan §7.1, v9 API).
 *
 * TanStack is only the view layer: rows and columns come from the sheet's
 * `SheetState` in server order, and nothing here ever reorders them. What
 * TanStack owns is per-user view state — column widths, the pinned start
 * edge, and row selection.
 *
 * Mount one per sheet (key the grid by sheet id): the width storage key is
 * fixed at setup.
 */
import { computed, h, ref, shallowRef, watch, type Ref } from 'vue'
import {
  columnPinningFeature,
  columnResizingFeature,
  columnSizingFeature,
  metaHelper,
  rowSelectionFeature,
  tableFeatures,
  useTable,
  type ColumnDef,
  type ColumnPinningState,
  type ColumnSizingState,
  type RowSelectionState,
  type Updater,
} from '@tanstack/vue-table'

import SheetCell from '@/components/sheet/SheetCell.vue'
import SheetRowGutter from '@/components/sheet/SheetRowGutter.vue'
import {
  GUTTER_COLUMN_ID,
  GUTTER_WIDTH,
  MIN_COLUMN_WIDTH,
  defaultWidth,
  gridTemplate,
  pinnedStart,
} from '@/lib/sheet/grid'
import type { SheetState } from '@/lib/sheet/state'
import type { Column, ColumnId, Row, SheetId } from '@/types/contract'

export interface SheetColumnMeta {
  /** The sheet column; `null` for the gutter. */
  column: Column | null
}

// Module scope: TanStack requires `features` to be stable.
export const sheetFeatures = tableFeatures({
  columnSizingFeature,
  columnResizingFeature,
  columnPinningFeature,
  rowSelectionFeature,
  columnMeta: metaHelper<SheetColumnMeta>(),
})

export type SheetFeatures = typeof sheetFeatures
type SheetColumnDef = ColumnDef<SheetFeatures, Row>

const EMPTY_COLUMNS: Column[] = []
const EMPTY_ROWS: Row[] = []

function resolve<T>(updater: Updater<T>, previous: T): T {
  return typeof updater === 'function' ? (updater as (old: T) => T)(previous) : updater
}

const gutterColumn: SheetColumnDef = {
  id: GUTTER_COLUMN_ID,
  size: GUTTER_WIDTH,
  enableResizing: false,
  meta: { column: null },
  header: '',
  cell: (ctx) =>
    h(SheetRowGutter, {
      index: ctx.row.index,
      selected: ctx.row.getIsSelected(),
      onToggle: (value: boolean) => ctx.row.toggleSelected(value),
    }),
}

function columnDef(column: Column): SheetColumnDef {
  return {
    id: column.id,
    accessorFn: (row) => row.cells[column.id] ?? null,
    size: defaultWidth(column),
    minSize: MIN_COLUMN_WIDTH,
    meta: { column },
    header: column.name,
    cell: (ctx) => h(SheetCell, { row: ctx.row.original, column }),
  }
}

/**
 * Widths are local to each user and never synced (§7.1). Storage can be
 * unavailable (private windows, blocked site data), which only costs the
 * user their widths.
 */
function useStoredWidths(sheetId: SheetId): Ref<ColumnSizingState> {
  const key = `sheet-widths:${sheetId}`
  let initial: ColumnSizingState = {}
  try {
    const raw = window.localStorage.getItem(key)
    if (raw) initial = JSON.parse(raw) as ColumnSizingState
  } catch {
    // Fall back to the defaults.
  }

  const widths = ref<ColumnSizingState>(initial)
  watch(widths, (value) => {
    try {
      window.localStorage.setItem(key, JSON.stringify(value))
    } catch {
      // Widths just won't survive a reload.
    }
  })
  return widths
}

export function useSheetTable(view: Ref<SheetState | null>, sheetId: SheetId) {
  // Separate computeds so a value edit (new `rows`, same `columns`) never
  // rebuilds the column defs: Vue only notifies when the array changes.
  const columns = computed(() => view.value?.columns ?? EMPTY_COLUMNS)
  const labelColumnId = computed(() => view.value?.labelColumnId ?? '')

  const data = shallowRef<Row[]>(EMPTY_ROWS)
  watch(
    () => view.value?.rows ?? EMPTY_ROWS,
    (rows) => {
      data.value = rows
    },
    { immediate: true },
  )

  const columnDefs = computed(() => [gutterColumn, ...columns.value.map(columnDef)])

  const columnSizing = useStoredWidths(sheetId)
  const rowSelection = ref<RowSelectionState>({})
  const columnPinning = computed<ColumnPinningState>(() => ({
    start: pinnedStart(labelColumnId.value),
    end: [],
  }))

  const table = useTable<SheetFeatures, Row>({
    features: sheetFeatures,
    data,
    columns: columnDefs,
    getRowId: (row) => row.id,
    columnResizeMode: 'onChange',
    autoResetAll: false,
    state: computed(() => ({
      columnSizing: columnSizing.value,
      rowSelection: rowSelection.value,
      columnPinning: columnPinning.value,
    })),
    onColumnSizingChange: (updater) => {
      columnSizing.value = resolve(updater, columnSizing.value)
    },
    onRowSelectionChange: (updater) => {
      rowSelection.value = resolve(updater, rowSelection.value)
    },
  })

  const rows = computed(() => table.getRowModel().rows)

  /** Pinned headers first, then the rest, in the order cells render. */
  const headers = computed(() => [...table.getStartLeafHeaders(), ...table.getCenterLeafHeaders()])

  const pinnedCount = computed(() => table.getStartLeafHeaders().length)

  const template = computed(() => gridTemplate(headers.value.map((header) => header.getSize())))

  /**
   * Navigable columns in *render* order. This is not `view.columns`: the label
   * column is pinned and renders first whatever its position, and Tab and Home
   * have to follow what the user sees. The gutter is never navigable.
   */
  const navColumnIds = computed(() =>
    headers.value.map((header) => header.column.id).filter((id) => id !== GUTTER_COLUMN_ID),
  )

  /** Width of the pinned start edge, which overlays the scrolled content. */
  const frozenWidth = computed(() =>
    table.getStartLeafHeaders().reduce((total, header) => total + header.getSize(), 0),
  )

  /**
   * A column's offset and width in the scrolled content, for bringing it into
   * view. Pinned columns return `null`: they are always visible, so there is
   * nothing to scroll to. `getStart('center')` is measured among the centre
   * columns alone, so the pinned tracks ahead of them have to be added back.
   */
  function columnRect(columnId: ColumnId): { start: number; size: number } | null {
    const header = headers.value.find((candidate) => candidate.column.id === columnId)
    if (!header || header.column.getIsPinned()) return null
    return {
      start: frozenWidth.value + header.column.getStart('center'),
      size: header.getSize(),
    }
  }

  return {
    table,
    rows,
    headers,
    pinnedCount,
    gridTemplate: template,
    rowSelection,
    navColumnIds,
    frozenWidth,
    columnRect,
  }
}
