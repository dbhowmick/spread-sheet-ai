/**
 * Column type → how its cells render and edit (frontend-plan §7.3). Adding a
 * type (currency, select…) means one entry here plus its components.
 */
import type { Component } from 'vue'

import type { Column, ColumnType } from '@/types/contract'

import BooleanDisplay from './BooleanDisplay.vue'
import CellEditor from './CellEditor.vue'
import DateDisplay from './DateDisplay.vue'
import DateEditor from './DateEditor.vue'
import LabelDisplay from './LabelDisplay.vue'
import NumberDisplay from './NumberDisplay.vue'
import TextDisplay from './TextDisplay.vue'

export type CellAlign = 'start' | 'end' | 'center'

export interface CellTypeDef {
  display: Component
  /** `null` where the cell has no editor: a boolean toggles in place. */
  editor: Component | null
  align: CellAlign
}

/**
 * Text, number and label all share `CellEditor`: they are the same typed-text
 * input, and what differs between them — parsing, the label uniqueness check —
 * happens once in `useGridNavigation.commit` so that paste takes the same path.
 */
export const cellTypes: Record<ColumnType, CellTypeDef> = {
  text: { display: TextDisplay, editor: CellEditor, align: 'start' },
  number: { display: NumberDisplay, editor: CellEditor, align: 'end' },
  boolean: { display: BooleanDisplay, editor: null, align: 'center' },
  date: { display: DateDisplay, editor: DateEditor, align: 'start' },
}

const labelType: CellTypeDef = { display: LabelDisplay, editor: CellEditor, align: 'start' }

/** The label column always renders as a label, whatever its (text) type. */
export function cellTypeFor(column: Column): CellTypeDef {
  return column.is_label ? labelType : cellTypes[column.column_type]
}
